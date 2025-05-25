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
    let uri: String // Added URI for adding to playlist
}
class SpotifyTrack {
    var albumArt: NSImage?
    var title: String
    var isLiked: Bool
    var uri: String

    init(albumArt: NSImage?, title: String, isLiked: Bool, uri: String) {
        self.albumArt = albumArt
        self.title = title
        self.isLiked = isLiked
        self.uri = uri
    }
}
// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    
    enum PlaybackState: CustomStringConvertible {
        case loading
        // Updated to include isActuallyPlaying
        case playing(track: CurrentlyPlayingTrack, isActuallyPlaying: Bool, isLiked: Bool, art: NSImage?)
        case notPlaying(message: String)
        case error(message: String)

        var description: String {
            switch self {
            case .loading: return "PlaybackState.loading"
            // Updated description
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
    
    var likeMenuItem: NSMenuItem?
    var authorizeMenuItem: NSMenuItem?
    var transferMenuItem: NSMenuItem?
    var addToPlaylistMenuItem: NSMenuItem?
    var playlistsSubmenu: NSMenu?
    
    var selectedDevice: (id: String, name: String)?
    var recentTracks: [SpotifyTrack] = []
    var lastNowPlayingImage: NSImage?
    private var internalCurrentPlaybackState: PlaybackState = .loading


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
        
        updateUI(for: .loading) // Initial UI state

        if let storedToken = SpotifyTokenStore.load() {
            self.tokenStore = storedToken
            if storedToken.isExpired {
                NSLog("🔑 Token expired, attempting refresh on launch.")
                refreshAccessToken()
            } else {
                self.authorizeMenuItem?.isHidden = true
                NSLog("✅ Loaded valid access token from disk.")
                triggerTrackUpdate() // Fetch track info if token is valid
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
        Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(triggerTrackUpdate), userInfo: nil, repeats: true)
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
    }
    func updateHistoryMenu() {
        // Remove old menu item if exists
        if let existingItemIndex = statusItem.menu?.items.firstIndex(where: { $0.identifier?.rawValue == "historyArrowItem" }) {
            statusItem.menu?.removeItem(at: existingItemIndex)
        }

        guard !recentTracks.isEmpty else { return }

        let arrowItem = NSMenuItem()
        arrowItem.identifier = NSUserInterfaceItemIdentifier("historyArrowItem")
        arrowItem.title = "▼"

        let historyMenu = NSMenu()

        for track in recentTracks {
            let item = NSMenuItem()
            item.representedObject = track

            let maxTitleLength = 30
            var displayTitle = track.title
            if displayTitle.count > maxTitleLength {
                let index = displayTitle.index(displayTitle.startIndex, offsetBy: maxTitleLength - 3)
                displayTitle = String(displayTitle[..<index]) + "..."
            }

            let attributed = NSMutableAttributedString()

            if let art = track.albumArt {
                let attachment = NSTextAttachment()
                attachment.image = art
                attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                attributed.append(NSAttributedString(attachment: attachment))
                attributed.append(NSAttributedString(string: " "))
            }

            attributed.append(NSAttributedString(string: displayTitle))

            if track.isLiked {
                attributed.append(NSAttributedString(string: " ⭐"))
            }

            item.attributedTitle = attributed
            item.toolTip = track.title
            item.target = self
            item.action = #selector(playTrackFromHistory(_:))

            historyMenu.addItem(item)
        }

        arrowItem.submenu = historyMenu
        statusItem.menu?.addItem(NSMenuItem.separator())
        statusItem.menu?.addItem(arrowItem)
    }
    func playTrackFromURI(_ uri: String) {
        guard let accessToken = tokenStore?.accessToken else {
            NSLog("❌ Missing access token")
            return
        }

        guard let url = URL(string: "https://api.spotify.com/v1/me/player/play") else { return }

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

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                NSLog("❌ Error starting playback: \(error)")
            } else if let httpResponse = response as? HTTPURLResponse {
                NSLog("ℹ️ Playback request returned status: \(httpResponse.statusCode)")
            } else {
                NSLog("✅ Playback request sent")
            }
        }.resume()
    }
    @objc func playTrackFromHistory(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? SpotifyTrack else { return }

        // Use your Spotify API instance to play the track by URI
        playTrackFromURI(track.uri)
            switch result {
            case .success:
                NSLog("🎶 Started playback for: \(track.title)")
            case .failure(let error):
                NSLog("❌ Failed to play track: \(error)")
            }
        }
    }
    // MARK: - Central UI Update Function
    func updateUI(for state: PlaybackState) {
        DispatchQueue.main.async {
            self.internalCurrentPlaybackState = state
            
            switch state {
            case .loading:
                // Keep the current UI state to prevent flickering during refresh.
                break

            case .notPlaying(let message):
                self.statusItem.button?.title = "\(message)" // Changed icon for clarity
                self.statusItem.button?.image = nil
                self.likeMenuItem?.isHidden = true
                self.addToPlaylistMenuItem?.isHidden = true
                self.transferMenuItem?.isHidden = true // Hide transfer if nothing is contextually available
                self.likeMenuItem?.title = "♡ Like Song"

            case .error(let message):
                self.statusItem.button?.title = "⚠️ \(message)"
                self.statusItem.button?.image = nil
                self.likeMenuItem?.isHidden = true
                self.addToPlaylistMenuItem?.isHidden = true
                self.transferMenuItem?.isHidden = true // Hide transfer on error too
                self.likeMenuItem?.title = "♡ Like Song"

            // Updated to handle isActuallyPlaying
            case .playing(let track, let isActuallyPlaying, let isLiked, let art):
                self.likeMenuItem?.isHidden = false
                self.addToPlaylistMenuItem?.isHidden = false
                self.transferMenuItem?.isHidden = false
                
                self.likeMenuItem?.isEnabled = true
                self.addToPlaylistMenuItem?.isEnabled = true
                self.transferMenuItem?.isEnabled = true
                self.likeMenuItem?.title = isLiked ? "♥ Unlike Song" : "♡ Like Song"
                
                // Add pause indicator if not actively playing
                let playStatusIndicator = isActuallyPlaying ? "" : "⏸ "
                let trackText = "\(playStatusIndicator)\(track.name) – \(track.artist)"
                let starText = isLiked ? " ⭐" : ""
                let font = NSFont.menuBarFont(ofSize: 0) // Size 0 uses system default menu bar font size
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

                let finalImage = NSImage(size: NSSize(width: totalWidth, height: 18)) // Standard menu bar height
                finalImage.lockFocus()

                var currentX: CGFloat = 0
                if let appIcon = NSImage(named: "AppIcon") { // Ensure AppIcon is in Assets
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
                    if art == nil && trackTextSize.width > 0 { currentX += spacing } // Add spacing if no art but has text
                    starTextAttributedString.draw(at: NSPoint(x: currentX, y: (finalImage.size.height - starTextSize.height) / 2))
                }
                finalImage.unlockFocus()
                let newTrack = SpotifyTrack(albumArt: art, title: track.name, isLiked: isLiked, uri: track.uri)
                if let existingIndex = recentTracks.firstIndex(where: { $0.uri == newTrack.uri }) {
                    recentTracks.remove(at: existingIndex)
                }
                recentTracks.insert(newTrack, at: 0)
                if recentTracks.count > 5 {
                    recentTracks.removeLast()
                }
                updateHistoryMenu()
                self.statusItem.button?.image = finalImage
                self.statusItem.button?.title = "" // Clear title when image is set
                self.lastNowPlayingImage = finalImage
            }
        }
    }
    
    // MARK: - Data Fetching & State Determination
    @objc func triggerTrackUpdate() {
        DispatchQueue.main.async { self.updateUI(for: .loading) }
        
        guard let token = tokenStore else {
            NSLog("ℹ️ No token store for track update.")
            if self.authorizeMenuItem?.isHidden == true {
                 updateUI(for: .notPlaying(message: "Refreshing Auth..."))
            } else {
                 updateUI(for: .notPlaying(message: "Please click to authorize"))
            }
            if tokenStore?.refreshToken != nil && (tokenStore?.isExpired ?? true) {
                refreshAccessToken()
            }
            return
        }

        if token.isExpired {
            NSLog("🔑 Token expired, attempting refresh for track update.")
            refreshAccessToken()
            return
        }
        
        // Short delay before fetching to allow UI to settle if needed, can be adjusted/removed
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            self.fetchCurrentTrackDetails(accessToken: token.accessToken)
        }
    }

    func fetchCurrentTrackDetails(accessToken: String) {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!) // Placeholder URL
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Playback info error: \(error.localizedDescription)")
                self.updateUI(for: .error(message: "Network Error"))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("❌ Invalid response from playback endpoint.")
                self.updateUI(for: .error(message: "Server Error"))
                return
            }

            if httpResponse.statusCode == 401 {
                NSLog("🔑 Access token unauthorized (401). Refreshing.")
                self.refreshAccessToken()
                return
            }
            
            // If 204 No Content, or if there's no data, it means nothing is loaded.
            if httpResponse.statusCode == 204 || data == nil {
                NSLog("ℹ️ Nothing currently loaded or playing (status: \(httpResponse.statusCode)).")
                self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                return
            }
            
            // Ensure data is present for further processing if not 204
            guard let data = data else { // Should be caught by above, but as a safeguard
                NSLog("❌ No data from playback, though status was not 204: \(httpResponse.statusCode)")
                self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                return
            }
            
            do {
                // Try to parse the JSON
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    NSLog("ℹ️ Could not parse JSON from playback data.")
                    self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                    return
                }

                // Check if there is a track item. If not, nothing is loaded.
                guard let item = json["item"] as? [String: Any] else {
                    NSLog("ℹ️ No track 'item' found in response. Nothing is loaded.")
                    self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                    return
                }
                
                // A track item exists, determine if it's actively playing
                let isActuallyPlaying = json["is_playing"] as? Bool ?? false

                // Parse track details from the 'item'
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let artistsArray = item["artists"] as? [[String: Any]] else {
                    NSLog("ℹ️ Could not parse essential track details from 'item'.")
                    self.updateUI(for: .notPlaying(message: "Nothing Playing")) // Treat as nothing playing if item is malformed
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
                self.checkIfTrackIsLiked(trackId: track.id, accessToken: accessToken) { liked in
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
                    // Update UI with track details, including its actual playing state
                    self.updateUI(for: .playing(track: track, isActuallyPlaying: isActuallyPlaying, isLiked: isLiked, art: albumArtImage))
                }
                
            } catch {
                NSLog("❌ Error parsing playback JSON: \(error.localizedDescription)")
                self.updateUI(for: .error(message: "Parse Error"))
            }
        }.resume()
    }

    // MARK: - Auth Logic
    @objc func authorizeSpotify() {
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d" // Replace with your actual Client ID
        let redirectURI = "spotify-menubar-app://callback" // Ensure this matches your Spotify App settings
        let scope = "user-read-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-modify-playback-state"

        self.codeVerifier = PKCE.generateCodeVerifier()
        guard let codeChallenge = PKCE.codeChallenge(for: self.codeVerifier!) else {
            NSLog("❌ Failed to generate code challenge.")
            return
        }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")! // Placeholder URL
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: UUID().uuidString) // Optional: for security
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
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")! // Placeholder URL
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let clientId = "c62a858a7ec0468194da1c197d3c4d3d" // Replace with your actual Client ID
        let redirectURI = "spotify-menubar-app://callback" // Ensure this matches
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
            if let error = error {
                NSLog("❌ Token exchange error: \(error.localizedDescription)")
                self.updateUI(for: .error(message: "Auth Failed"))
                return
            }
            guard let data = data else {
                NSLog("❌ No data from token exchange.")
                self.updateUI(for: .error(message: "Auth Failed"))
                return
            }
            
            do {
                var tokenDataFromJSON = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
                tokenDataFromJSON.expirationDate = Date().addingTimeInterval(tokenDataFromJSON.expiresIn) // Calculate expiration
                tokenDataFromJSON.save()
                self.tokenStore = tokenDataFromJSON
                NSLog("✅ Token exchanged and saved successfully.")
                DispatchQueue.main.async {
                    self.authorizeMenuItem?.isHidden = true
                    self.triggerTrackUpdate() // Update track info now that we're authorized
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
        // Optionally update UI to show "Refreshing Auth..." or similar
        // updateUI(for: .loading) // Or a specific "refreshing auth" state

        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")! // Placeholder URL
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d" // Replace with your actual Client ID
        let params = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Token refresh network error: \(error.localizedDescription)")
                self.handleTokenRefreshFailure()
                return
            }
            guard let data = data else {
                NSLog("❌ No data from token refresh.")
                self.handleTokenRefreshFailure()
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 400 { // Specifically check for 400 on refresh
                 NSLog("❌ Token refresh failed (400 Bad Request - often invalid refresh token). User needs to re-authorize.")
                 self.handleTokenRefreshFailure(isAuthError: true) // Treat as auth error
                 return
            }

            do {
                var refreshedTokenData = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
                refreshedTokenData.expirationDate = Date().addingTimeInterval(refreshedTokenData.expiresIn)
                // Preserve the original refresh token if the response doesn't include a new one
                if refreshedTokenData.refreshToken == nil {
                    refreshedTokenData.refreshToken = refreshToken
                }
                self.tokenStore = refreshedTokenData
                self.tokenStore?.save()
                NSLog("🔄 Token refreshed and saved successfully.")
                DispatchQueue.main.async {
                    self.authorizeMenuItem?.isHidden = true // Ensure authorize is hidden
                    self.triggerTrackUpdate() // Refresh track info with new token
                }
            } catch {
                NSLog("❌ Failed to decode refreshed token: \(error.localizedDescription). Response: \(String(data: data, encoding: .utf8) ?? "Non-UTF8 data")")
                self.handleTokenRefreshFailure()
            }
        }.resume()
    }
    
    func handleTokenRefreshFailure(isAuthError: Bool = false) {
        if isAuthError {
            SpotifyTokenStore.delete() // Clear out the bad token
            self.tokenStore = nil
            DispatchQueue.main.async {
                self.authorizeMenuItem?.isHidden = false // Show authorize option
                self.updateUI(for: .notPlaying(message: "Please click to authorize"))
            }
            NSLog("🔑 Token refresh failed due to auth error. User needs to re-authorize.")
        } else {
            // For non-auth errors (e.g., network), you might just show an error message
            // and let the app try again later, or keep the current state.
            DispatchQueue.main.async {
                self.updateUI(for: .error(message: "Auth Refresh Failed"))
            }
            NSLog("🔑 Token refresh failed (e.g. network issue).")
        }
    }
    
    @objc func resetAuthorization() {
        SpotifyTokenStore.delete()
        self.tokenStore = nil
        self.codeVerifier = nil // Clear PKCE verifier
        DispatchQueue.main.async {
            self.authorizeMenuItem?.isHidden = false
            self.updateUI(for: .notPlaying(message: "Please click to authorize"))
        }
        NSLog("🗑 Authorization reset by user.")
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Track Actions (Like, Playlist)
    func loadAlbumArt(from urlString: String, completion: @escaping (NSImage?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error {
                NSLog("🎨 Error downloading album art: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let data = data, let image = NSImage(data: data) else {
                completion(nil)
                return
            }
            // Resize image for menu bar
            let targetSize = NSSize(width: 16, height: 16) // Standard icon size
            let resizedImage = NSImage(size: targetSize)
            resizedImage.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: targetSize),
                       from: NSRect(origin: .zero, size: image.size), // Draw entire source image into target
                       operation: .sourceOver,
                       fraction: 1.0)
            resizedImage.unlockFocus()
            completion(resizedImage)
        }.resume()
    }

    func checkIfTrackIsLiked(trackId: String, accessToken: String, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackId)")!) // Placeholder URL
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Failed to check liked status: \(error.localizedDescription)")
                completion(false); return
            }
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [Bool], // Spotify returns an array of booleans
                  let isLiked = result.first else {
                NSLog("❌ Could not parse liked status or non-200 response. Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                completion(false); return
            }
            completion(isLiked)
        }.resume()
    }

    @objc func toggleLikeStatus() {
        NSLog("⭐️ Toggle Like Status Action Triggered. Current internal state: \(self.internalCurrentPlaybackState)")
        guard let currentToken = tokenStore, !currentToken.isExpired else {
            NSLog("ℹ️ Not authorized (token missing/expired) to toggle like.")
            self.triggerTrackUpdate() // Attempt to refresh token/state
            return
        }
        
        let currentPlaybackState = getCurrentPlaybackStateForAction()
        NSLog("ℹ️ Current Playback State for Action: \(currentPlaybackState)")

        // Updated guard to match new PlaybackState.playing structure
        guard case .playing(let track, _, _, _) = currentPlaybackState else {
            NSLog("ℹ️ No track playing/paused to toggle like. Guard failed. Current state was: \(currentPlaybackState)")
            if likeMenuItem?.isEnabled == true {
                NSLog("⚠️ Like button was enabled, but state is not .playing. Triggering update.")
                self.triggerTrackUpdate()
            }
            return
        }

        let trackID = track.id
        NSLog("👍 Track is loaded: \(track.name) (ID: \(trackID)). Proceeding to check liked status.")

        checkIfTrackIsLiked(trackId: trackID, accessToken: currentToken.accessToken) { isCurrentlyLiked in
            NSLog("❓ Track \(trackID) is currently liked: \(isCurrentlyLiked). Attempting to set to \(!isCurrentlyLiked).")
            let method = isCurrentlyLiked ? "DELETE" : "PUT"
            var likeRequest = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackID)")!) // Placeholder URL
            
            likeRequest.httpMethod = method
            likeRequest.setValue("Bearer \(currentToken.accessToken)", forHTTPHeaderField: "Authorization")
            likeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type") // Required for PUT/DELETE with body

            let bodyParams = ["ids": [trackID]]
            likeRequest.httpBody = try? JSONSerialization.data(withJSONObject: bodyParams)
            
            URLSession.shared.dataTask(with: likeRequest) { _, response, error in
                if let error = error {
                    NSLog("❌ Error toggling like status for track \(trackID): \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                    NSLog("✅ Like status toggled successfully for track \(trackID). New state: \(!isCurrentlyLiked)")
                } else {
                    NSLog("❌ Failed to toggle like status for track \(trackID). Code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                // Refresh UI regardless of success/failure to reflect potential changes
                DispatchQueue.main.async { self.triggerTrackUpdate() }
            }.resume()
        }
    }
    
    func getCurrentPlaybackStateForAction() -> PlaybackState {
        // This ensures that actions are always based on the most recent, centrally stored state.
        return self.internalCurrentPlaybackState
    }

    // MARK: - Playlist Management
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == self.playlistsSubmenu {
            NSLog("🔎 Playlists submenu needs update. Fetching playlists...")
            menu.removeAllItems() // Clear old items
            let loadingItem = NSMenuItem(title: "Loading playlists...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false // Non-interactive
            menu.addItem(loadingItem)
            fetchUserPlaylists()
        }
    }

    func fetchUserPlaylists() {
        guard let token = tokenStore, !token.isExpired else {
            updatePlaylistsSubmenu(with: .failure(NSError(domain: "SpotifyApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not authorized"])))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")!) // Placeholder URL
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Failed to fetch playlists: \(error.localizedDescription)")
                self.updatePlaylistsSubmenu(with: .failure(error))
                return
            }
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let fetchError = NSError(domain: "SpotifyApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch playlists. Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
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
                NSLog("❌ Error parsing playlists JSON: \(error.localizedDescription)")
                self.updatePlaylistsSubmenu(with: .failure(error))
            }
        }.resume()
    }

    func updatePlaylistsSubmenu(with result: Result<[PlaylistSummary], Error>) {
        DispatchQueue.main.async {
            guard let menu = self.playlistsSubmenu else { return }
            menu.removeAllItems() // Clear loading/previous items

            switch result {
            case .success(let playlists):
                if playlists.isEmpty {
                    menu.addItem(NSMenuItem(title: "No playlists found", action: nil, keyEquivalent: ""))
                } else {
                    playlists.forEach { playlist in
                        let item = NSMenuItem(title: playlist.name, action: #selector(self.addCurrentSongToSelectedPlaylist(_:)), keyEquivalent: "")
                        item.representedObject = playlist.id // Store ID for action
                        item.target = self // Ensure action is called on AppDelegate
                        menu.addItem(item)
                    }
                }
            case .failure(let error):
                let errorItem = NSMenuItem(title: "Error loading playlists", action: nil, keyEquivalent: "")
                errorItem.toolTip = error.localizedDescription // Show error on hover
                menu.addItem(errorItem)
            }
        }
    }
    
    @objc func addCurrentSongToSelectedPlaylist(_ sender: NSMenuItem) {
        guard let playlistId = sender.representedObject as? String else {
            NSLog("❌ Playlist ID not found for adding song.")
            showErrorAlert(title: "Error", message: "Could not identify the selected playlist.")
            return
        }
        guard let token = tokenStore, !token.isExpired else {
            showErrorAlert(title: "Authorization Error", message: "Please authorize the app first.")
            return
        }
        
        // Updated guard to match new PlaybackState.playing structure
        guard case .playing(let track, _, _, _) = self.internalCurrentPlaybackState else {
            showErrorAlert(title: "Error Adding Song", message: "No song is currently playing or paused.")
            NSLog("ℹ️ No track loaded to add to playlist. Current state: \(self.internalCurrentPlaybackState)")
            return
        }
        let trackURI = track.uri

        NSLog("🎵 Adding track URI \(trackURI) to playlist \(playlistId)")
        
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks")!) // Placeholder URL
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["uris": [trackURI]] // Spotify API expects an array of URIs
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showErrorAlert(title: "Error Adding Song", message: "Network error: \(error.localizedDescription)")
                    return
                }
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 201 { // 201 Created is success for this endpoint
                        self.showSuccessAlert(title: "Song Added", message: "Successfully added '\(track.name)' to playlist '\(sender.title)'.")
                    } else {
                        var errorMessage = "Failed to add song. Status: \(httpResponse.statusCode)"
                        if let responseData = data,
                           let jsonError = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                           let errorObj = jsonError["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                            errorMessage = msg
                        }
                        self.showErrorAlert(title: "Error Adding Song", message: errorMessage)
                    }
                } else {
                     self.showErrorAlert(title: "Error Adding Song", message: "Invalid response from server.")
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

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/devices")!) // Placeholder URL
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showErrorAlert(title: "Device Error", message: "Could not fetch devices: \(error.localizedDescription)")
                    return
                }
                guard let data = data,
                      let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let devices = json["devices"] as? [[String: Any]] else {
                    self.showErrorAlert(title: "Device Error", message: "Could not parse device list. Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    return
                }

                if devices.isEmpty {
                    self.showErrorAlert(title: "No Devices", message: "No active Spotify devices found. Make sure Spotify is open on a device.")
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
                        popup.lastItem?.representedObject = id // Store ID
                    }
                }
                alert.accessoryView = popup

                if alert.runModal() == .alertFirstButtonReturn { // User clicked OK
                    if let selectedItem = popup.selectedItem, let deviceId = selectedItem.representedObject as? String {
                        self.transferPlaybackToSelectedDevice(deviceId: deviceId, deviceName: selectedItem.title)
                    }
                }
            }
        }.resume()
    }

    @objc func transferPlaybackToSelectedDevice(deviceId: String, deviceName: String) {
        guard let token = tokenStore, !token.isExpired else {
            showErrorAlert(title: "Authorization Error", message: "Please authorize the app first.")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!) // Placeholder URL
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Spotify API: 'play' can be set to true to start playback, false to keep current state.
        // Setting to true is usually desired for a transfer action.
        let body: [String: Any] = ["device_ids": [deviceId], "play": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showErrorAlert(title: "Transfer Error", message: "Could not transfer playback: \(error.localizedDescription)")
                    return
                }
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 204 { // 204 No Content is success
                        NSLog("✅ Playback transferred successfully to \(deviceName).")
                        self.showSuccessAlert(title: "Playback Transferred", message: "Playback transferred to \(deviceName).")
                        self.triggerTrackUpdate() // Refresh to show current state on new device
                    } else {
                        var errorMessage = "Transfer failed. Status: \(httpResponse.statusCode)"
                         if let responseData = data,
                           let jsonError = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                           let errorObj = jsonError["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                            errorMessage += "\nDetails: \(msg)"
                        }
                        self.showErrorAlert(title: "Transfer Failed", message: errorMessage)
                    }
                } else {
                    self.showErrorAlert(title: "Transfer Error", message: "Invalid response from server.")
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
            alert.alertStyle = .informational // Use .informational for success
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    // MARK: - App Behavior
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // This prevents a new window from opening if the app icon is clicked in the Dock
        // when it's already running as a menu bar app.
        return false
    }
}

// MARK: - PKCE (Proof Key for Code Exchange) Helper
struct PKCE {
    static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32) // 32 bytes = 256 bits
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64URLEncodedString() // Using custom extension below
    }

    static func codeChallenge(for verifier: String) -> String? {
        guard let data = verifier.data(using: .utf8) else { return nil }
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64URLEncodedString() // Using custom extension below
    }
}

// Custom extension for base64URL encoding (RFC 4648)
extension Data {
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") // Remove padding
    }
}

// MARK: - Token Storage
struct SpotifyTokenStore: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: TimeInterval // Time in seconds until token expires
    var expirationDate: Date? // Calculated date of expiration

    var isExpired: Bool {
        guard let date = expirationDate else { return true } // If no date, assume expired
        return date < Date() // Compare with current time
    }

    // CodingKeys to map JSON keys from Spotify to struct properties
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        // expirationDate is not in the JSON, it's calculated client-side
    }

    // File URL for storing the token
    static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpotifyMenubarApp", isDirectory: true) // App-specific directory
        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir.appendingPathComponent("spotify_tokens.json")
    }()

    // Save the token store to disk
    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.fileURL, options: .atomicWrite) // Atomic write for safety
            NSLog("💾 Token saved to \(Self.fileURL.path)")
        } catch {
            NSLog("❌ Failed to save token: \(error.localizedDescription)")
        }
    }
    
    // Load the token store from disk
    static func load() -> SpotifyTokenStore? {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            NSLog("ℹ️ No token file found at \(Self.fileURL.path)")
            return nil
        }
        do {
            // When decoding, also calculate expirationDate if it wasn't saved (older versions)
            var tokenStore = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
            if tokenStore.expirationDate == nil { // For backward compatibility or if not set
                 tokenStore.expirationDate = Date().addingTimeInterval(tokenStore.expiresIn)
            }
            NSLog("✅ Token loaded from \(Self.fileURL.path)")
            return tokenStore
        } catch {
            NSLog("❌ Failed to decode token from file: \(error.localizedDescription). Deleting corrupt file.")
            delete() // Delete corrupt token file to prevent repeated errors
            return nil
        }
    }
    
    // Delete the token file
    static func delete() {
        do {
            try FileManager.default.removeItem(at: fileURL)
            NSLog("🗑 Token file deleted from \(Self.fileURL.path)")
        } catch {
            // Log error but don't crash; app can continue by prompting for re-auth
            NSLog("❌ Failed to delete token file: \(error.localizedDescription)")
        }
    }
}
