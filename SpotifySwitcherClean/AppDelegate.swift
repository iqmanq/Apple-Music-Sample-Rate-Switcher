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

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    
    enum PlaybackState: CustomStringConvertible { // Added CustomStringConvertible for easier logging
        case loading
        case playing(track: CurrentlyPlayingTrack, isLiked: Bool, art: NSImage?)
        case notPlaying(message: String)
        case error(message: String)

        var description: String {
            switch self {
            case .loading: return "PlaybackState.loading"
            case .playing(let track, let isLiked, _): return "PlaybackState.playing(track: \(track.name), isLiked: \(isLiked))"
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { // Shortened delay
                if self.tokenStore == nil { // Check again in case auth happened quickly
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
        playlistsSubmenu!.delegate = self // For dynamic playlist loading
        menu.addItem(addToPlaylistMenuItem!)
        
        transferMenuItem = NSMenuItem(title: "Transfer Playback...", action: #selector(promptForDeviceTransfer), keyEquivalent: "")
        menu.addItem(transferMenuItem!)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }

    // MARK: - Central UI Update Function
    func updateUI(for state: PlaybackState) {
        DispatchQueue.main.async {
            self.internalCurrentPlaybackState = state
            // NSLog("🔄 UI Update. New internal state: \(self.internalCurrentPlaybackState)") // Verbose logging
            
            switch state { // Use the passed-in state for the switch
            case .loading:
                self.statusItem.button?.image = self.lastNowPlayingImage
                self.statusItem.button?.title = ""
                self.statusItem.button?.image = nil
                self.likeMenuItem?.isEnabled = false
                self.addToPlaylistMenuItem?.isEnabled = false
                self.transferMenuItem?.isEnabled = false
                self.likeMenuItem?.title = "♡ Like Song"

            case .notPlaying(let message):
                self.statusItem.button?.title = "⏸ \(message)"
                self.statusItem.button?.image = nil
                self.likeMenuItem?.isEnabled = false
                self.addToPlaylistMenuItem?.isEnabled = false
                self.transferMenuItem?.isEnabled = true
                self.likeMenuItem?.title = "♡ Like Song"

            case .error(let message):
                self.statusItem.button?.title = "⚠️ \(message)"
                self.statusItem.button?.image = nil
                self.likeMenuItem?.isEnabled = false
                self.addToPlaylistMenuItem?.isEnabled = false
                self.transferMenuItem?.isEnabled = true
                self.likeMenuItem?.title = "♡ Like Song"

            case .playing(let track, let isLiked, let art):
                self.likeMenuItem?.isEnabled = true
                self.addToPlaylistMenuItem?.isEnabled = true
                self.transferMenuItem?.isEnabled = true
                self.likeMenuItem?.title = isLiked ? "♥ Unlike Song" : "♡ Like Song"
                
                let trackText = "\(track.name) – \(track.artist)"
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
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            self.fetchCurrentTrackDetails(accessToken: token.accessToken)
        }
    }

    func fetchCurrentTrackDetails(accessToken: String) {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
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
            
            if httpResponse.statusCode == 204 {
                NSLog("ℹ️ Nothing currently playing (204 No Content).")
                self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                return
            }

            guard let data = data, httpResponse.statusCode == 200 else {
                NSLog("❌ No data or non-200 response from playback: \(httpResponse.statusCode)")
                self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                return
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let isPlaying = json["is_playing"] as? Bool, isPlaying,
                      let item = json["item"] as? [String: Any],
                      let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let artistsArray = item["artists"] as? [[String: Any]] else {
                    NSLog("ℹ️ Could not parse track, or track is not currently playing.")
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
                    self.updateUI(for: .playing(track: track, isLiked: isLiked, art: albumArtImage))
                }
                
            } catch {
                NSLog("❌ Error parsing playback JSON: \(error.localizedDescription)")
                self.updateUI(for: .error(message: "Parse Error"))
            }
        }.resume()
    }

    // MARK: - Auth Logic
    @objc func authorizeSpotify() {
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
        let redirectURI = "spotify-menubar-app://callback"
        let scope = "user-read-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-modify-playback-state"

        self.codeVerifier = PKCE.generateCodeVerifier()
        guard let codeChallenge = PKCE.codeChallenge(for: self.codeVerifier!) else {
            NSLog("❌ Failed to generate code challenge.")
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
                tokenDataFromJSON.expirationDate = Date().addingTimeInterval(tokenDataFromJSON.expiresIn)
                tokenDataFromJSON.save()
                self.tokenStore = tokenDataFromJSON
                NSLog("✅ Token exchanged and saved successfully.")
                DispatchQueue.main.async {
                    self.authorizeMenuItem?.isHidden = true
                    self.triggerTrackUpdate()
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
        updateUI(for: .notPlaying(message: "Refreshing Auth..."))


        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
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
                    self.triggerTrackUpdate()
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
        self.tokenStore = nil
        self.codeVerifier = nil
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
            let targetSize = NSSize(width: 16, height: 16)
            let resizedImage = NSImage(size: targetSize)
            resizedImage.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: targetSize),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .sourceOver,
                       fraction: 1.0)
            resizedImage.unlockFocus()
            completion(resizedImage)
        }.resume()
    }

    func checkIfTrackIsLiked(trackId: String, accessToken: String, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackId)")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Failed to check liked status: \(error.localizedDescription)")
                completion(false)
                return
            }
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [Bool],
                  let isLiked = result.first else {
                NSLog("❌ Could not parse liked status or non-200 response. Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                completion(false)
                return
            }
            completion(isLiked)
        }.resume()
    }

    @objc func toggleLikeStatus() {
        NSLog("⭐️ Toggle Like Status Action Triggered. Current internal state: \(self.internalCurrentPlaybackState)")
        guard let currentToken = tokenStore, !currentToken.isExpired else {
            NSLog("ℹ️ Not authorized (token missing/expired) to toggle like.")
            self.triggerTrackUpdate()
            return
        }
        
        // Use the centrally stored playback state
        let currentPlaybackState = getCurrentPlaybackStateForAction()
        NSLog("ℹ️ Current Playback State for Action: \(currentPlaybackState)")

        guard case .playing(let track, _, _) = currentPlaybackState else {
            NSLog("ℹ️ No track playing to toggle like. Guard failed. Current state was: \(currentPlaybackState)")
            // If the button was somehow enabled while not in .playing state, this log will show it.
            // Optionally, try to refresh state if it seems inconsistent.
            if likeMenuItem?.isEnabled == true { // If button is enabled but state isn't .playing
                NSLog("⚠️ Like button was enabled, but state is not .playing. Triggering update.")
                self.triggerTrackUpdate()
            }
            return
        }

        // If guard passes, 'track' is now defined and in scope.
        let trackID = track.id // Explicitly define trackID
        NSLog("👍 Track is playing: \(track.name) (ID: \(trackID)). Proceeding to check liked status.")

        checkIfTrackIsLiked(trackId: trackID, accessToken: currentToken.accessToken) { isCurrentlyLiked in
            NSLog("❓ Track \(trackID) is currently liked: \(isCurrentlyLiked). Attempting to set to \(!isCurrentlyLiked).")
            let method = isCurrentlyLiked ? "DELETE" : "PUT"
            
            // The line you mentioned (547 in your local file) would be around here.
            // This line itself does not use 'trackId' or 'track.id' directly for its own definition.
            var likeRequest = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackID)")!)
            
            likeRequest.httpMethod = method
            likeRequest.setValue("Bearer \(currentToken.accessToken)", forHTTPHeaderField: "Authorization")
            likeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let bodyParams = ["ids": [trackID]] // Use the explicitly defined trackID
            likeRequest.httpBody = try? JSONSerialization.data(withJSONObject: bodyParams)
            
            URLSession.shared.dataTask(with: likeRequest) { _, response, error in
                if let error = error {
                    NSLog("❌ Error toggling like status for track \(trackID): \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                    NSLog("✅ Like status toggled successfully for track \(trackID). New state: \(!isCurrentlyLiked)")
                } else {
                    NSLog("❌ Failed to toggle like status for track \(trackID). Code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                DispatchQueue.main.async {
                    self.triggerTrackUpdate()
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
            NSLog("❌ Playlist ID not found for adding song.")
            showErrorAlert(title: "Error", message: "Could not identify the selected playlist.")
            return
        }
        guard let token = tokenStore, !token.isExpired else {
            showErrorAlert(title: "Authorization Error", message: "Please authorize the app first.")
            return
        }
        
        guard case .playing(let track, _, _) = self.internalCurrentPlaybackState else {
            showErrorAlert(title: "Error Adding Song", message: "No song is currently playing.")
            NSLog("ℹ️ No track playing to add to playlist. Current state: \(self.internalCurrentPlaybackState)")
            return
        }
        let trackURI = track.uri

        NSLog("🎵 Adding track URI \(trackURI) to playlist \(playlistId)")
        
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["uris": [trackURI]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showErrorAlert(title: "Error Adding Song", message: "Network error: \(error.localizedDescription)")
                    return
                }
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 201 {
                        self.showSuccessAlert(title: "Song Added", message: "Successfully added to playlist '\(sender.title)'.")
                    } else {
                        var errorMessage = "Failed to add song. Status: \(httpResponse.statusCode)"
                        if let responseData = data,
                           let jsonError = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                           let errorObj = jsonError["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                            errorMessage = msg // Use specific error from Spotify if available
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

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/devices")!)
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
                        popup.lastItem?.representedObject = id
                    }
                }
                alert.accessoryView = popup

                if alert.runModal() == .alertFirstButtonReturn {
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

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["device_ids": [deviceId], "play": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showErrorAlert(title: "Transfer Error", message: "Could not transfer playback: \(error.localizedDescription)")
                    return
                }
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 204 {
                        NSLog("✅ Playback transferred successfully to \(deviceName).")
                        self.showSuccessAlert(title: "Playback Transferred", message: "Playback transferred to \(deviceName).")
                        self.triggerTrackUpdate()
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
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    static func codeChallenge(for verifier: String) -> String? {
        guard let data = verifier.data(using: .utf8) else { return nil }
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64URLEncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

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
            NSLog("ℹ️ No token file found at \(Self.fileURL.path)")
            return nil
        }
        do {
            let tokenStore = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
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
