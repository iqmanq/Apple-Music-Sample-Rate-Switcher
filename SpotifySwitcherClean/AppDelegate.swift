import Cocoa
import SpotifyWebAPI
import CryptoKit
import Security

// MARK: - Data Encryption Helper
struct DataEncryptionHelper {
    private let keychainService: String
    private let keychainAccount: String

    init(keychainService: String, keychainAccount: String) {
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    func encrypt(_ data: Data) -> Data? {
        guard let key = getEncryptionKey() else { return nil }
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            return sealedBox.combined
        } catch {
            NSLog("❌ [EncryptionHelper] Failed to encrypt data for service '\(keychainService)': \(error)")
            return nil
        }
    }

    func decrypt(_ data: Data) -> Data? {
        guard let key = getEncryptionKey() else { return nil }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            return decryptedData
        } catch {
            NSLog("❌ [EncryptionHelper] Failed to decrypt data for service '\(keychainService)': \(error). Data might be corrupt or key changed.")
            return nil
        }
    }

    func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            NSLog("🗑 Encryption key for service '\(keychainService)' deleted from Keychain.")
        } else {
            let errorMessage = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            NSLog("❌ Failed to delete encryption key for service '\(keychainService)': \(errorMessage) (Status: \(status))")
        }
    }

    private func getEncryptionKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess {
            if let retrievedData = dataTypeRef as? Data {
                return SymmetricKey(data: retrievedData)
            }
        }
        if status == errSecItemNotFound {
            let newKey = SymmetricKey(size: .bits256)
            let keyData = newKey.withUnsafeBytes { Data(Array($0)) }
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                NSLog("🔑 New encryption key created and saved to Keychain for service '\(keychainService)'.")
                return newKey
            } else {
                let errorMessage = SecCopyErrorMessageString(addStatus, nil) as String? ?? "Unknown error"
                NSLog("❌ Failed to save new encryption key to Keychain for service '\(keychainService)': \(errorMessage) (Status: \(addStatus))")
            }
        }
        if status != errSecSuccess && status != errSecItemNotFound {
             let errorMessage = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
             NSLog("❌ Unhandled error when loading encryption key for service '\(keychainService)': \(errorMessage) (Status: \(status))")
        }
        return nil
    }
}

// MARK: - Data Models
struct PlaylistSummary {let id: String; let name: String}
struct CurrentlyPlayingTrack {let id: String; let name: String; let artist: String; let artworkURL: String?; let uri: String}
struct PlaybackContext {let isPlaying: Bool; let isLiked: Bool; let shuffleState: Bool; let repeatState: String; let volumePercent: Int}
struct SpotifyTrack: Codable, Equatable, Hashable {
    var id: String; var title: String; var artistName: String; var isLiked: Bool; var uri: String; var artworkURL: String?
    static func == (lhs: SpotifyTrack, rhs: SpotifyTrack) -> Bool { return lhs.uri == rhs.uri }
    func hash(into hasher: inout Hasher) { hasher.combine(uri) }
}

// MARK: - Device Storage
struct SpotifyDeviceStore: Codable {
    var id: String; var name: String
    private static let encryptionHelper = DataEncryptionHelper(keychainService: "com.iqraamanuel.SpotifySwitcherClean.DeviceStoreKey", keychainAccount: "deviceStore")
    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpotifyMenubarApp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil) }
        return dir.appendingPathComponent("spotify_device.encrypted")
    }()
    func save() {
        do {
            let plaintextData = try JSONEncoder().encode(self)
            guard let encryptedData = Self.encryptionHelper.encrypt(plaintextData) else { NSLog("❌ Failed to encrypt device data."); return }
            try encryptedData.write(to: Self.fileURL, options: .atomicWrite); NSLog("💾 Encrypted device data saved.")
        } catch { NSLog("❌ Failed to save encrypted device data: \(error)") }
    }
    static func load() -> SpotifyDeviceStore? {
        guard let encryptedData = try? Data(contentsOf: Self.fileURL) else { return nil }
        guard let decryptedData = encryptionHelper.decrypt(encryptedData) else { NSLog("❌ Failed to decrypt device data. Deleting corrupt file."); delete(); return nil }
        do { let deviceStore = try JSONDecoder().decode(SpotifyDeviceStore.self, from: decryptedData); NSLog("✅ Encrypted device data loaded."); return deviceStore }
        catch { NSLog("❌ Failed to decode decrypted device data: \(error)"); return nil }
    }
    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        encryptionHelper.deleteKey(); NSLog("🗑 Encrypted device file and key deleted.")
    }
}

// MARK: - Token Storage
struct SpotifyTokenStore: Codable {
    let accessToken: String; var refreshToken: String?; let expirationDate: Date
    private let expiresIn: TimeInterval?
    var isExpired: Bool { return expirationDate < Date() }
    private static let keychainService = "com.iqraamanuel.SpotifySwitcherClean.TokenService"
    private static let keychainAccount = "spotifyUserToken"
    private enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", expirationDate }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try container.decode(String.self, forKey: .accessToken)
        self.refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        
        if let expDate = try container.decodeIfPresent(Date.self, forKey: .expirationDate) {
            self.expirationDate = expDate
            self.expiresIn = nil
        } else if let expIn = try container.decodeIfPresent(TimeInterval.self, forKey: .expiresIn) {
            self.expiresIn = expIn
            self.expirationDate = Date().addingTimeInterval(expIn)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .expiresIn, in: container, debugDescription: "Token data must contain 'expires_in' or 'expirationDate'.")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encode(expirationDate, forKey: .expirationDate)
    }

    func save() {
        do {
            let tokenData = try JSONEncoder().encode(self)
            var error: Unmanaged<CFError>?
            let access = SecAccessControlCreateWithFlags(kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .applicationPassword, &error)
            guard let accessControl = access else { NSLog("❌ Failed to create Keychain access control: \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")"); return }
            let query: [String: Any] = [ kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: SpotifyTokenStore.keychainService, kSecAttrAccount as String: SpotifyTokenStore.keychainAccount, kSecValueData as String: tokenData, kSecAttrAccessControl as String: accessControl ]
            SecItemDelete(query as CFDictionary)
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { NSLog("💾 Token saved to Keychain successfully (with .applicationPassword).") }
            else { let err = SecCopyErrorMessageString(status, nil) as String?; NSLog("❌ Failed to save token to Keychain: \(err ?? "Unknown OSStatus") (Status: \(status))") }
        } catch { NSLog("❌ Failed to encode token for Keychain storage: \(error)") }
    }
    static func load() -> SpotifyTokenStore? {
        let query: [String: Any] = [ kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount, kSecReturnData as String: kCFBooleanTrue!, kSecMatchLimit as String: kSecMatchLimitOne ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            guard let retrievedData = dataTypeRef as? Data else { return nil }
            do { let tokenStore = try JSONDecoder().decode(SpotifyTokenStore.self, from: retrievedData); NSLog("✅ Token loaded from Keychain."); return tokenStore }
            catch { NSLog("❌ Failed to decode token from Keychain: \(error). Deleting corrupt item."); delete(); return nil }
        } else if status == errSecItemNotFound { NSLog("ℹ️ No token found in Keychain for service '\(keychainService)'.")
        } else { let err = SecCopyErrorMessageString(status, nil) as String?; NSLog("❌ Error loading token from Keychain: \(err ?? "Unknown OSStatus") (Status: \(status))") }
        return nil
    }
    static func delete() {
        let query: [String: Any] = [ kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { NSLog("🗑 Token deleted from Keychain.") }
        else { let err = SecCopyErrorMessageString(status, nil) as String?; NSLog("❌ Failed to delete token from Keychain: \(err ?? "Unknown OSStatus") (Status: \(status))") }
    }
}


class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    
    enum PlaybackState: CustomStringConvertible {
        case loading
        case playing(track: CurrentlyPlayingTrack, context: PlaybackContext, art: NSImage?)
        case notPlaying(message: String)
        case error(message: String)

        var description: String {
            switch self {
            case .loading: return "PlaybackState.loading"
            case .playing(let track, let context, _): return "PlaybackState.playing(track: \(track.name), isPlaying: \(context.isPlaying))"
            case .notPlaying(let message): return "PlaybackState.notPlaying(message: \"\(message)\")"
            case .error(let message): return "PlaybackState.error(message: \"\(message)\")"
            }
        }
    }
    
    var statusItem: NSStatusItem!
    var codeVerifier: String?
    var tokenStore: SpotifyTokenStore?
    var preferredDevice: SpotifyDeviceStore?
    
    var miniPlayerView: MiniPlayerView?
    var miniPlayerMenuItem: NSMenuItem?

    var authorizeMenuItem: NSMenuItem?
    var transferMenuItem: NSMenuItem?
    var addToPlaylistMenuItem: NSMenuItem?
    var playlistsSubmenu: NSMenu?
    
    var recentTracks: [SpotifyTrack] = []
    private var internalCurrentPlaybackState: PlaybackState = .loading
    private var dataUpdateTimer: Timer?
    private var lastSeenTrackURI: String?
    private var isFetchingData: Bool = false
    // NEW: Rate Limit properties
    private var isRateLimited: Bool = false
    private var rateLimitMessageTimer: Timer?

    private let historyMenuItemIdentifier = NSUserInterfaceItemIdentifier("historyMenuItem")
    private let historySeparatorIdentifier = NSUserInterfaceItemIdentifier("historySeparator")
    
    private let recentTracksEncryptionHelper = DataEncryptionHelper(keychainService: "com.iqraamanuel.SpotifySwitcherClean.RecentTracksKey", keychainAccount: "recentTracks")
    
    override init() { super.init() }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Spotify Mini Player"

        setupMenu()
        loadRecentTracks()
        
        if let storedDevice = SpotifyDeviceStore.load() { self.preferredDevice = storedDevice }
        
        updateUI(for: .loading)

        if let storedToken = SpotifyTokenStore.load() {
            self.tokenStore = storedToken
            if storedToken.isExpired {
                refreshAccessToken()
            } else {
                authorizeMenuItem?.isHidden = true
                updateAllData()
                startDataUpdateTimer()
            }
        } else {
            authorizeMenuItem?.isHidden = false
            miniPlayerMenuItem?.isHidden = true
            updateUI(for: .notPlaying(message: "Authorize"))
        }
    }
    
    func startDataUpdateTimer() {
        dataUpdateTimer?.invalidate()
        dataUpdateTimer = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(updateAllDataWrapper), userInfo: nil, repeats: true) // Increased interval
        NSLog("🕰️ Data update timer started (15s interval).")
    }

    func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        miniPlayerMenuItem = NSMenuItem()
        self.miniPlayerView = MiniPlayerView(frame: NSRect(x: 0, y: 0, width: 200, height: 85))
        self.miniPlayerView?.appDelegate = self
        miniPlayerMenuItem!.view = self.miniPlayerView
        miniPlayerMenuItem!.isHidden = true
        menu.addItem(miniPlayerMenuItem!)
        
        menu.addItem(NSMenuItem.separator())
        
        authorizeMenuItem = NSMenuItem(title: "Authorize Spotify", action: #selector(authorizeSpotify), keyEquivalent: "")
        menu.addItem(authorizeMenuItem!)
        
        menu.addItem(NSMenuItem(title: "Reset Authorization", action: #selector(resetAuthorization), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        addToPlaylistMenuItem = NSMenuItem(title: "Add song to playlist...", action: nil, keyEquivalent: "")
        playlistsSubmenu = NSMenu()
        addToPlaylistMenuItem!.submenu = playlistsSubmenu
        playlistsSubmenu!.delegate = self
        menu.addItem(addToPlaylistMenuItem!)
        
        transferMenuItem = NSMenuItem(title: "Transfer Playback...", action: #selector(promptForDeviceTransfer), keyEquivalent: "")
        menu.addItem(transferMenuItem!)
        
        menu.addItem(NSMenuItem.separator())
        
        // NEW: Rate Limit message item, initially hidden
        let rateLimitInfoItem = NSMenuItem(title: "Rate Limited: Try again later.", action: nil, keyEquivalent: "")
        rateLimitInfoItem.tag = 999 // Unique tag for identification
        rateLimitInfoItem.isHidden = true // Initially hidden
        menu.addItem(rateLimitInfoItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
        updateHistoryMenu(excluding: nil)
    }

    // MARK: - NSMenuDelegate
    func menuWillOpen(_ menu: NSMenu) {
        NSLog("ℹ️ menuWillOpen called for: \(menu)")
        if menu == statusItem.menu {
            if let button = statusItem.button {
                let statusItemWidth = button.frame.width
                let desiredPlayerWidth = statusItemWidth - 16
                
                if let playerView = self.miniPlayerMenuItem?.view {
                    var currentFrame = playerView.frame
                    if abs(currentFrame.width - desiredPlayerWidth) > 1.0 {
                        NSLog("Adjusting player width from \(currentFrame.width) to \(desiredPlayerWidth) (status item width: \(statusItemWidth))")
                        currentFrame.size.width = max(200, desiredPlayerWidth)
                        playerView.frame = currentFrame
                    }
                }
            }
            // NEW: Control visibility of the rate limit message menu item
            if let rateLimitItem = menu.item(withTag: 999) {
                rateLimitItem.isHidden = !self.isRateLimited
                NSLog("Debug: Rate Limit menu item hidden status: \(rateLimitItem.isHidden) (isRateLimited: \(self.isRateLimited))")
            }

            // Fetch recently played only when the main menu is about to open and not already fetching
            if tokenStore != nil && !(tokenStore!.isExpired) && !isFetchingData {
                fetchRecentlyPlayed()
            }
        }
        if menu == self.playlistsSubmenu {
            menu.removeAllItems()
            let loadingItem = NSMenuItem(title: "Loading playlists...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
            fetchUserPlaylists()
        }
    }
            
    func updateHistoryMenu(excluding currentTrackURI: String?) {
        guard let menu = statusItem.menu else { return }

        menu.items.filter { $0.identifier == historyMenuItemIdentifier || $0.identifier == historySeparatorIdentifier }.forEach { menu.removeItem($0) }

        let tracksToShow = recentTracks.filter { $0.uri != currentTrackURI }
        guard !tracksToShow.isEmpty else { return }

        let historyMenuItem = NSMenuItem()
        historyMenuItem.identifier = historyMenuItemIdentifier
        historyMenuItem.title = "Recently Played..."
        let historySubmenu = NSMenu()

        for track in tracksToShow.prefix(10) {
            let item = NSMenuItem()
            item.representedObject = track
            var displayTitle = track.title
            if displayTitle.count > 25 { displayTitle = String(displayTitle.prefix(22)) + "..." }
            
            let attributedTitle = NSMutableAttributedString(string: " " + displayTitle)
            if track.isLiked { attributedTitle.append(NSAttributedString(string: " ⭐")) }
            item.attributedTitle = attributedTitle
            item.toolTip = "\(track.title) - \(track.artistName)"
            item.target = self
            item.action = #selector(playTrackFromHistory(_:))
            
            if let artworkURLString = track.artworkURL {
                loadAlbumArt(from: artworkURLString, forHistory: true, specificSize: NSSize(width: 16, height: 16)) { image in
                    guard let image = image else { return }
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                    
                    let newAttributedTitleWithArt = NSMutableAttributedString()
                    newAttributedTitleWithArt.append(NSAttributedString(attachment: attachment))
                    newAttributedTitleWithArt.append(NSAttributedString(string: " " + displayTitle))
                    if track.isLiked { newAttributedTitleWithArt.append(NSAttributedString(string: " ⭐")) }
                    item.attributedTitle = newAttributedTitleWithArt
                }
            }
            historySubmenu.addItem(item)
        }
        historyMenuItem.submenu = historySubmenu

        var insertionPoint = menu.items.count - 1
        if let quitItemIndex = menu.items.firstIndex(where: { $0.action == #selector(quitApp) }) {
            insertionPoint = quitItemIndex
        }
        
        let separator = NSMenuItem.separator()
        separator.identifier = historySeparatorIdentifier
        menu.insertItem(separator, at: insertionPoint)
        menu.insertItem(historyMenuItem, at: insertionPoint + 1)
    }
    
    @objc func playTrackFromHistory(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? SpotifyTrack else { return }
        playTrackFromURI(track.uri)
    }

    func playTrackFromURI(_ uri: String) {
        guard let accessToken = tokenStore?.accessToken else { NSLog("❌ PlayTrackFromURI: No access token"); return }
        let body: [String: Any] = ["uris": [uri]]
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            performPlayerAction(endpoint: "/me/player/play", method: "PUT", body: bodyData)
        } catch {
            NSLog("❌ Failed to serialize play URI body: \(error)")
        }
    }
    
    func updateUI(for state: PlaybackState) {
        DispatchQueue.main.async {
            self.internalCurrentPlaybackState = state // Always store the latest state

            let isAuthorized = (self.tokenStore != nil && !(self.tokenStore!.isExpired))
            self.authorizeMenuItem?.isHidden = isAuthorized
            
            // These should remain visible even if rate-limited, as per user request.
            self.addToPlaylistMenuItem?.isHidden = false
            self.transferMenuItem?.isHidden = false
            self.miniPlayerMenuItem?.isHidden = false

            var currentTrackURI: String? = nil // Declare currentTrackURI here

            // Only update the status bar if the temporary "Rate Limited" message is NOT active
            if self.rateLimitMessageTimer == nil {
                self.statusItem.button?.image = nil // Clear image first
                self.statusItem.button?.title = "Loading..." // Default text


                switch state {
                case .loading:
                    self.statusItem.button?.title = "Loading..."
                    self.statusItem.button?.toolTip = "Loading Spotify Data..."
                    if isAuthorized {
                        self.miniPlayerView?.update(isPlaying: false, shuffleState: false, repeatState: "off", isLiked: false, volume: 50)
                    }

                case .notPlaying(let message):
                    self.statusItem.button?.title = isAuthorized ? "Nothing Playing" : message
                    self.statusItem.button?.toolTip = isAuthorized ? "Nothing Playing" : message
                    
                    self.transferMenuItem?.isHidden = self.preferredDevice == nil || !isAuthorized
                    
                    if isAuthorized {
                        self.miniPlayerView?.update(isPlaying: false, shuffleState: false, repeatState: "off", isLiked: false, volume: 50)
                    } else {
                        self.miniPlayerMenuItem?.isHidden = true
                    }

                case .error(let message):
                    // If rate-limited, the status bar title will come from showRateLimitedStatusTemporarily
                    // This case handles other errors.
                    self.statusItem.button?.title = "Error"
                    self.statusItem.button?.toolTip = "Error: \(message)"

                case .playing(let track, let context, let art):
                    currentTrackURI = track.uri // Set currentTrackURI here, always if in playing state

                    // Only update mini player view if not rate limited, to avoid stale data
                    if !self.isRateLimited {
                        self.miniPlayerView?.update(isPlaying: context.isPlaying,
                                                    shuffleState: context.shuffleState,
                                                    repeatState: context.repeatState,
                                                    isLiked: context.isLiked,
                                                    volume: context.volumePercent)
                        
                        let appIcon = NSImage(named: "AppIcon")
                        let playPauseIndicator = context.isPlaying ? "" : "⏸ "
                        let fullTitle = "\(playPauseIndicator)\(track.name) – \(track.artist)"
                        let starForStatusBar = context.isLiked ? "⭐" : ""

                        let textAttributes: [NSAttributedString.Key: Any] = [
                            .font: NSFont.menuBarFont(ofSize: NSFont.systemFontSize(for: .small)),
                            .foregroundColor: NSColor.labelColor
                        ]
                        let titleAttributedString = NSAttributedString(string: fullTitle, attributes: textAttributes)
                        let starAttributedString = NSAttributedString(string: starForStatusBar, attributes: textAttributes)

                        let iconSize = NSSize(width: 16, height: 16)
                        let spacing: CGFloat = 3.0
                        
                        var currentX: CGFloat = 0
                        var totalWidth: CGFloat = 0
                        
                        if let appIcon = appIcon { totalWidth += iconSize.width + spacing }
                        totalWidth += titleAttributedString.size().width + spacing
                        if let art = art { totalWidth += iconSize.width + spacing }
                        if context.isLiked { totalWidth += starAttributedString.size().width + spacing }
                        totalWidth -= spacing

                        let compositeImage = NSImage(size: NSSize(width: max(1,totalWidth), height: iconSize.height))
                        compositeImage.lockFocus()

                        if let appIcon = appIcon {
                            let resizedAppIcon = appIcon.copy() as! NSImage
                            resizedAppIcon.size = iconSize
                            resizedAppIcon.draw(at: NSPoint(x: currentX, y: (compositeImage.size.height - iconSize.height) / 2), from: .zero, operation: .sourceOver, fraction: 1.0)
                            currentX += iconSize.width + spacing
                        }
                        titleAttributedString.draw(at: NSPoint(x: currentX, y: (compositeImage.size.height - titleAttributedString.size().height) / 2))
                        currentX += titleAttributedString.size().width + spacing
                        if let albumArt = art {
                            let resizedAlbumArt = albumArt.copy() as! NSImage
                            resizedAlbumArt.size = iconSize
                            resizedAlbumArt.draw(at: NSPoint(x: currentX, y: (compositeImage.size.height - iconSize.height) / 2), from: .zero, operation: .sourceOver, fraction: 1.0)
                            currentX += iconSize.width + spacing
                        }
                        if context.isLiked {
                            starAttributedString.draw(at: NSPoint(x: currentX, y: (compositeImage.size.height - starAttributedString.size().height) / 2))
                        }
                        compositeImage.unlockFocus()
                        self.statusItem.button?.image = compositeImage
                        self.statusItem.button?.title = ""
                        self.statusItem.button?.toolTip = "\(track.name) – \(track.artist)"
                    } else {
                        // If rate limited, but we were playing, maintain the last known song title in status bar.
                        let playPauseIndicator = context.isPlaying ? "" : "⏸ " // Use context from the current state
                        let fullTitle = "\(playPauseIndicator)\(track.name) – \(track.artist)"
                        self.statusItem.button?.title = fullTitle
                        self.statusItem.button?.toolTip = "\(track.name) – \(track.artist)"
                        self.statusItem.button?.image = nil // Clear image if not actively updating
                    }
                }
            } // End of if self.rateLimitMessageTimer == nil
            
            // This line is outside the `if self.rateLimitMessageTimer == nil` block,
            // so `currentTrackURI` must be reliably set by all paths above.
            if self.statusItem.menu != nil {
                self.updateHistoryMenu(excluding: currentTrackURI)
            }
        }
    }
    
    @objc func updateAllDataWrapper() {
        guard !isFetchingData else {
            NSLog("🔄 Data fetch already in progress, skipping timer fire.")
            return
        }
        updateAllData()
    }
    
    @objc func updateAllData() {
        NSLog("🔄 Updating current track details (called by timer or manually)...")
        guard tokenStore != nil && !(tokenStore!.isExpired) else {
            NSLog("🔑 No valid token or token expired, skipping data update.")
            if tokenStore?.isExpired ?? true {
                refreshAccessToken()
            } else {
                DispatchQueue.main.async { self.updateUI(for: .notPlaying(message: "Authorize")) }
            }
            return
        }
        
        isFetchingData = true
        fetchCurrentTrackDetails()
        // fetchRecentlyPlayed() is now primarily called in menuWillOpen
    }
    
    func fetchCurrentTrackDetails() {
        guard let token = tokenStore, !token.isExpired else {
            DispatchQueue.main.async { self.isFetchingData = false }
            return
        }
        NSLog("📡 Fetching current track details...")
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { DispatchQueue.main.async { self.isFetchingData = false } }

            if let error = error { self.updateUI(for: .error(message: "Network: \(error.localizedDescription.prefix(20))")); return }
            guard let httpResponse = response as? HTTPURLResponse else { self.updateUI(for: .error(message: "Server Error")); return }

            if httpResponse.statusCode == 401 { self.refreshAccessToken(); return }
            if httpResponse.statusCode == 204 || data == nil { self.updateUI(for: .notPlaying(message: "Nothing Playing")); return }
            if httpResponse.statusCode == 429 {
                NSLog("‼️ Rate limit hit on fetchCurrentTrackDetails. Pausing timer.");
                self.dataUpdateTimer?.invalidate()
                self.isRateLimited = true // Set the flag for the persistent menu item
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    self.startDataUpdateTimer()
                    self.isRateLimited = false // Reset the flag after cooldown
                    self.updateUI(for: self.internalCurrentPlaybackState) // Revert UI after rate limit cooldown
                }
                // Do NOT call updateUI here to change the status bar title.
                // The existing internalCurrentPlaybackState will be used by updateUI,
                // and the menu item will reflect the rate limit.
                return
            }

            guard let data = data, httpResponse.statusCode == 200 else {
                self.updateUI(for: .error(message: "API Error (\(httpResponse.statusCode))")); return
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let item = json["item"] as? [String: Any] else {
                    self.updateUI(for: .notPlaying(message: "No Track Info")); return
                }
                
                guard let id = item["id"] as? String, let name = item["name"] as? String, let uri = item["uri"] as? String,
                      let artistsArray = item["artists"] as? [[String: Any]] else {
                    self.updateUI(for: .error(message: "Track Parse Error")); return
                }
                let artistNames = artistsArray.compactMap { $0["name"] as? String }.joined(separator: ", ")
                let albumData = item["album"] as? [String: Any]
                let imagesData = albumData?["images"] as? [[String: Any]]
                let artworkURL = imagesData?.first?["url"] as? String
                
                let currentTrack = CurrentlyPlayingTrack(id: id, name: name, artist: artistNames, artworkURL: artworkURL, uri: uri)
                
                let device = json["device"] as? [String: Any]
                let group = DispatchGroup()
                var isCurrentlyLiked = false
                var albumArtForStatusBar: NSImage? = nil

                group.enter()
                self.checkIfTracksAreLiked(trackIds: [id], accessToken: token.accessToken) { likedStatuses in
                    isCurrentlyLiked = likedStatuses[id] ?? false
                    group.leave()
                }
                
                if let artURL = artworkURL {
                    group.enter()
                    self.loadAlbumArt(from: artURL, forHistory: false, specificSize: NSSize(width: 16, height: 16)) { image in
                        albumArtForStatusBar = image
                        group.leave()
                    }
                }
                // No else { group.leave() } needed for art if not entered
                
                group.notify(queue: .main) {
                    let playbackContext = PlaybackContext(
                        isPlaying: json["is_playing"] as? Bool ?? false,
                        isLiked: isCurrentlyLiked,
                        shuffleState: json["shuffle_state"] as? Bool ?? false,
                        repeatState: json["repeat_state"] as? String ?? "off",
                        volumePercent: device?["volume_percent"] as? Int ?? 50
                    )
                    
                    if uri != self.lastSeenTrackURI {
                        let newHistoryTrack = SpotifyTrack(id: id, title: name, artistName: artistNames, isLiked: playbackContext.isLiked, uri: uri, artworkURL: artworkURL)
                        self.recentTracks.removeAll { $0.uri == uri }
                        self.recentTracks.insert(newHistoryTrack, at: 0)
                        if self.recentTracks.count > 20 { self.recentTracks = Array(self.recentTracks.prefix(20)) }
                        self.saveRecentTracks()
                        self.lastSeenTrackURI = uri
                    } else if let index = self.recentTracks.firstIndex(where: { $0.id == id }) {
                        self.recentTracks[index].isLiked = playbackContext.isLiked
                    }
                    self.updateUI(for: .playing(track: currentTrack, context: playbackContext, art: albumArtForStatusBar))
                }
            } catch {
                self.updateUI(for: .error(message: "JSON Parse Error"))
            }
        }.resume()
    }
    
    func fetchRecentlyPlayed() {
        guard let token = tokenStore, !token.isExpired, !isFetchingData else {
            if isFetchingData { NSLog("ℹ️ Already fetching data, skipping fetchRecentlyPlayed for now.") }
            return
        }
        isFetchingData = true // Set flag for this specific fetch
        NSLog("📡 Fetching recently played tracks (on menu open)...")
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=20")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.isFetchingData = false } } // Clear flag

            if let error = error { NSLog("❌ Recently Played Network Error: \(error.localizedDescription)"); return }
            guard let httpResponse = response as? HTTPURLResponse else { NSLog("❌ Recently Played: Invalid response."); return }
            
            if httpResponse.statusCode == 429 {
                NSLog("‼️ Rate limit hit on fetchRecentlyPlayed.");
                self.isRateLimited = true // Set the flag for the persistent menu item
                DispatchQueue.main.async { self.updateUI(for: self.internalCurrentPlaybackState) } // Update UI for menu item visibility
                return
            }
            guard httpResponse.statusCode == 200, let data = data else {
                NSLog("❌ Recently Played API Error: \(httpResponse.statusCode)"); return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["items"] as? [[String: Any]] else {
                    NSLog("❌ Could not parse recently played items."); return
                }
                
                let trackIdsToFetch = items.compactMap { ($0["track"] as? [String: Any])?["id"] as? String }
                guard !trackIdsToFetch.isEmpty else {
                     DispatchQueue.main.async { self.updateHistoryMenu(excluding: self.lastSeenTrackURI) }
                    return
                }

                self.checkIfTracksAreLiked(trackIds: trackIdsToFetch, accessToken: token.accessToken) { likedStatuses in
                    var parsedTracks: [SpotifyTrack] = []
                    for item in items {
                        guard let trackData = item["track"] as? [String: Any],
                              let name = trackData["name"] as? String,
                              let uri = trackData["uri"] as? String,
                              let trackIdFromApi = trackData["id"] as? String else { continue }
                        
                        let artistsArray = trackData["artists"] as? [[String: Any]]
                        let artistName = artistsArray?.compactMap({ $0["name"] as? String }).joined(separator: ", ") ?? "Unknown Artist"
                        let albumData = trackData["album"] as? [String: Any]
                        let imagesData = albumData?["images"] as? [[String: Any]]
                        let artworkURL = imagesData?.first?["url"] as? String
                        
                        parsedTracks.append(SpotifyTrack(id: trackIdFromApi, title: name, artistName: artistName, isLiked: likedStatuses[trackIdFromApi] ?? false, uri: uri, artworkURL: artworkURL))
                    }
                    
                    DispatchQueue.main.async {
                        var updatedRecentTracks = parsedTracks
                        let newTrackURIs = Set(parsedTracks.map { $0.uri })
                        for oldTrack in self.recentTracks {
                            if !newTrackURIs.contains(oldTrack.uri) {
                                updatedRecentTracks.append(oldTrack)
                            }
                        }
                        var finalUniqueTracks: [SpotifyTrack] = []
                        var seenURIs = Set<String>()
                        for track in updatedRecentTracks {
                            if !seenURIs.contains(track.uri) {
                                finalUniqueTracks.append(track)
                                seenURIs.insert(track.uri)
                            }
                        }
                        self.recentTracks = Array(finalUniqueTracks.prefix(10))
                        self.saveRecentTracks()
                        self.updateHistoryMenu(excluding: self.lastSeenTrackURI)
                    }
                }
            } catch { NSLog("❌ Error parsing recently played JSON: \(error.localizedDescription)") }
        }.resume()
    }
    func getRecentTracksFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpotifyMenubarApp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil) }
        return dir.appendingPathComponent("spotify_recent_tracks.encrypted")
    }

    func saveRecentTracks() {
        do {
            let tracksToSave = Array(self.recentTracks.prefix(20))
            let plaintextData = try JSONEncoder().encode(tracksToSave)
            guard let encryptedData = recentTracksEncryptionHelper.encrypt(plaintextData) else { NSLog("❌ Failed to encrypt recent tracks for saving."); return }
            try encryptedData.write(to: getRecentTracksFileURL(), options: .atomicWrite); NSLog("💾 Encrypted recent tracks saved.")
        } catch { NSLog("❌ Failed to save recent tracks: \(error)") }
    }

    func loadRecentTracks() {
        let fileURL = getRecentTracksFileURL()
        guard let encryptedData = try? Data(contentsOf: fileURL) else { NSLog("ℹ️ No recent tracks file found."); return }
        guard let decryptedData = recentTracksEncryptionHelper.decrypt(encryptedData) else {
            NSLog("❌ Failed to decrypt recent tracks. Deleting corrupt file."); try? FileManager.default.removeItem(at: fileURL); return
        }
        do { self.recentTracks = try JSONDecoder().decode([SpotifyTrack].self, from: decryptedData); NSLog("✅ Recent tracks loaded and decrypted.") }
        catch { NSLog("❌ Failed to decode recent tracks: \(error)") }
    }
    
    func deleteRecentTracks() {
        try? FileManager.default.removeItem(at: getRecentTracksFileURL())
        recentTracksEncryptionHelper.deleteKey(); NSLog("🗑 Encrypted recent tracks file and key deleted.")
    }

    @objc func authorizeSpotify() {
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
        let redirectURI = "spotify-menubar-app://callback"
        let scope = "user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-read-recently-played"
        self.codeVerifier = PKCE.generateCodeVerifier()
        guard let verifier = self.codeVerifier, let challenge = PKCE.codeChallenge(for: verifier) else { NSLog("❌ Failed to generate PKCE challenge."); return }
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "scope", value: scope), // Added scope here
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        guard let url = components.url else { NSLog("❌ Failed to build Spotify auth URL."); return }
        NSWorkspace.shared.open(url); NSLog("🔑 Opened Spotify authorization URL.")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            NSLog("❌ Auth callback did not contain code."); return
        }
        NSLog("✅ Received authorization code.")
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
          let params = [ "client_id": clientId, "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "code_verifier": verifier ]
          request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
          URLSession.shared.dataTask(with: request) { data, response, error in
              guard let data = data, error == nil else { self.updateUI(for: .error(message: "Auth Failed")); return }
              do {
                  let tokenDataFromAPI = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
                  tokenDataFromAPI.save()
                  self.tokenStore = tokenDataFromAPI
                  DispatchQueue.main.async {
                      self.authorizeMenuItem?.isHidden = true
                      self.updateAllData()
                      self.startDataUpdateTimer()
                  }
              } catch { self.updateUI(for: .error(message: "Token Decode Error")) }
          }.resume()
      }

    func refreshAccessToken() {
            guard let currentTokenStore = tokenStore, let refreshToken = currentTokenStore.refreshToken else {
                handleTokenRefreshFailure(isAuthError: true); return
            }
            let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
            let params = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId]
            request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                guard let data = data, error == nil else { self.handleTokenRefreshFailure(); return }
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 400 {
                     self.handleTokenRefreshFailure(isAuthError: true); return
                }
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 { // Added rate limit handling
                    NSLog("‼️ Rate limit hit on refreshAccessToken.")
                    self.isRateLimited = true // Set the flag for the persistent menu item
                    DispatchQueue.main.async { self.updateUI(for: self.internalCurrentPlaybackState) } // Update UI for menu item visibility
                    return
                }
                do {
                    var refreshedTokenData = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
                    if refreshedTokenData.refreshToken == nil { refreshedTokenData.refreshToken = refreshToken }
                    refreshedTokenData.save()
                    self.tokenStore = refreshedTokenData
                    DispatchQueue.main.async {
                        self.authorizeMenuItem?.isHidden = true
                        self.updateAllData()
                        self.startDataUpdateTimer()
                    }
                } catch { self.handleTokenRefreshFailure() }
            }.resume()
        }
    
    func handleTokenRefreshFailure(isAuthError: Bool = false) {
        if isAuthError {
            NSLog("🔑 Auth error during token refresh. Deleting token and requiring re-auth.")
            SpotifyTokenStore.delete()
            self.tokenStore = nil
            DispatchQueue.main.async {
                self.authorizeMenuItem?.isHidden = false
                self.miniPlayerMenuItem?.isHidden = true
                self.updateUI(for: .notPlaying(message: "Re-authorize"))
            }
        } else {
            NSLog("🔑 Non-auth token refresh failure (e.g., network).")
            DispatchQueue.main.async { self.updateUI(for: .error(message: "Auth Refresh Failed")) }
        }
    }
    
    @objc func resetAuthorization() {
        NSLog("🗑 Resetting all authorization and user data.")
        SpotifyTokenStore.delete(); SpotifyDeviceStore.delete(); deleteRecentTracks()
        self.tokenStore = nil; self.preferredDevice = nil; self.recentTracks = []; self.codeVerifier = nil
        DispatchQueue.main.async {
            self.authorizeMenuItem?.isHidden = false
            self.miniPlayerMenuItem?.isHidden = true
            self.updateUI(for: .notPlaying(message: "Authorize"))
            self.updateHistoryMenu(excluding: nil)
        }
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    func loadAlbumArt(from urlString: String, forHistory: Bool, specificSize: NSSize? = nil, completion: @escaping (NSImage?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, let image = NSImage(data: data), error == nil else { completion(nil); return }
            let targetSize = specificSize ?? (forHistory ? NSSize(width: 16, height: 16) : NSSize(width: 32, height: 32))
            let resizedImage = NSImage(size: targetSize)
            resizedImage.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .sourceOver, fraction: 1.0)
            resizedImage.unlockFocus()
            DispatchQueue.main.async { completion(resizedImage) }
        }.resume()
    }
    
    func checkIfTracksAreLiked(trackIds: [String], accessToken: String, completion: @escaping ([String: Bool]) -> Void) {
        guard !trackIds.isEmpty else { completion([:]); return }
        
        let chunkedTrackIds = trackIds.chunked(into: 50)
        var results: [String: Bool] = [:]
        let group = DispatchGroup()

        for chunk in chunkedTrackIds {
            group.enter()
            let idsString = chunk.joined(separator: ",")
            var urlComponents = URLComponents(string: "https://api.spotify.com/v1/me/tracks/contains")!
            urlComponents.queryItems = [URLQueryItem(name: "ids", value: idsString)]
            guard let url = urlComponents.url else { group.leave(); continue }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { group.leave(); return }
                defer { group.leave() }
                if let error = error { NSLog("❌ Error checking liked status for chunk: \(error.localizedDescription)"); return }
                guard let data = data, let httpResponse = response as? HTTPURLResponse else {
                    NSLog("❌ Invalid response checking liked status for chunk. Response: \(String(describing: response))")
                    return
                }
                if httpResponse.statusCode == 429 {
                    NSLog("‼️ Rate limit hit on checkIfTracksAreLiked. (Chunk: \(idsString))")
                    self.isRateLimited = true // Set the flag for the persistent menu item
                    DispatchQueue.main.async { self.updateUI(for: self.internalCurrentPlaybackState) } // Update UI for menu item visibility
                    return
                }
                guard httpResponse.statusCode == 200 else {
                    NSLog("❌ Invalid status code \(httpResponse.statusCode) checking liked status for chunk.")
                    return
                }
                do {
                    if let apiResponse = try JSONSerialization.jsonObject(with: data) as? [Bool] {
                        for (index, liked) in apiResponse.enumerated() {
                            if index < chunk.count { results[chunk[index]] = liked }
                        }
                    } else { NSLog("❌ Could not parse liked status JSON for chunk.") }
                } catch { NSLog("❌ Error parsing liked status JSON for chunk: \(error.localizedDescription)") }
            }.resume()
        }
        
        group.notify(queue: .main) {
            completion(results)
        }
    }

    @objc func toggleLikeStatus() {
        guard let token = tokenStore, !token.isExpired, case .playing(let track, let context, _) = internalCurrentPlaybackState else {
            NSLog("⚠️ Cannot toggle like: No valid token or not in playing state.")
            return
        }
        let method = context.isLiked ? "DELETE" : "PUT"
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks")!)
        request.httpMethod = method
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": [track.id]])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error { NSLog("❌ Error toggling like status for track \(track.id): \(error.localizedDescription)"); return }
            guard let httpResponse = response as? HTTPURLResponse else { NSLog("❌ Invalid response when toggling like status for track \(track.id)."); return }
            
            if httpResponse.statusCode == 429 {
                NSLog("‼️ Rate limit hit on toggleLikeStatus.")
                self.isRateLimited = true // Set the flag for the persistent menu item
                DispatchQueue.main.async { self.showRateLimitedStatusTemporarily() }
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                NSLog("✅ Like status toggled successfully for track \(track.id). Status: \(httpResponse.statusCode)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.updateAllData() }
            } else {
                NSLog("❌ Failed to toggle like status for track \(track.id). Code: \(httpResponse.statusCode)")
                if let responseData = data, let errorBody = String(data: responseData, encoding: .utf8) { NSLog("❌ Spotify Error Body: \(errorBody)") }
            }
        }.resume()
    }
    
    func fetchUserPlaylists() {
        guard let token = tokenStore, !token.isExpired else {
            updatePlaylistsSubmenu(with: .failure(NSError(domain: "SpotifyApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not authorized"]))); return
        }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/playlists")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error { self.updatePlaylistsSubmenu(with: .failure(error)); return }
            guard let data = data, let httpResponse = response as? HTTPURLResponse else {
                self.updatePlaylistsSubmenu(with: .failure(NSError(domain: "SpotifyApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch playlists."]))); return
            }

            if httpResponse.statusCode == 429 { // Added rate limit handling
                NSLog("‼️ Rate limit hit on fetchUserPlaylists.")
                self.isRateLimited = true // Set the flag for the persistent menu item
                DispatchQueue.main.async { self.updateUI(for: self.internalCurrentPlaybackState) } // Update UI for menu item visibility
                self.updatePlaylistsSubmenu(with: .failure(NSError(domain: "SpotifyApp", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited while fetching playlists."])))
                return
            }

            guard httpResponse.statusCode == 200 else {
                self.updatePlaylistsSubmenu(with: .failure(NSError(domain: "SpotifyApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch playlists. Status: \(httpResponse.statusCode)"]))); return
            }

            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = jsonResponse["items"] as? [[String: Any]] {
                    let playlists: [PlaylistSummary] = items.compactMap { dict in
                        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
                        return PlaylistSummary(id: id, name: name)
                    }
                    self.updatePlaylistsSubmenu(with: .success(playlists))
                } else { self.updatePlaylistsSubmenu(with: .failure(NSError(domain: "SpotifyApp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not parse playlists."]))) }
            } catch { self.updatePlaylistsSubmenu(with: .failure(error)) }
        }.resume()
    }

    func updatePlaylistsSubmenu(with result: Result<[PlaylistSummary], Error>) {
        DispatchQueue.main.async {
            guard let menu = self.playlistsSubmenu else { return }
            menu.removeAllItems()
            switch result {
            case .success(let playlists):
                if playlists.isEmpty { menu.addItem(NSMenuItem(title: "No playlists found", action: nil, keyEquivalent: "")) }
                else { playlists.forEach { playlist in
                        let item = NSMenuItem(title: playlist.name, action: #selector(self.addCurrentSongToSelectedPlaylist(_:)), keyEquivalent: "")
                        item.representedObject = playlist.id; item.target = self; menu.addItem(item)
                }}
            case .failure(let error):
                let errorItem = NSMenuItem(title: "Error loading playlists", action: nil, keyEquivalent: ""); errorItem.toolTip = error.localizedDescription; menu.addItem(errorItem)
            }
        }
    }
    
    @objc func addCurrentSongToSelectedPlaylist(_ sender: NSMenuItem) {
        guard let playlistId = sender.representedObject as? String else { showErrorAlert(title: "Error", message: "Could not identify playlist."); return }
        guard let token = tokenStore, !token.isExpired, case .playing(let track, _, _) = internalCurrentPlaybackState else { showErrorAlert(title: "Error", message: "No song playing or not authorized."); return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["uris": [track.uri]])
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 429 {
                        NSLog("‼️ Rate limit hit on addCurrentSongToSelectedPlaylist.")
                        self.isRateLimited = true // Set the flag for the persistent menu item
                        self.showRateLimitedStatusTemporarily()
                        return
                    }
                    if httpResponse.statusCode == 201 {
                        self.showSuccessAlert(title: "Song Added", message: "Added '\(track.name)' to playlist '\(sender.title)'.")
                    } else { self.showErrorAlert(title: "Error Adding Song", message: "Failed to add. Code: \(httpResponse.statusCode)") }
                } else { self.showErrorAlert(title: "Error Adding Song", message: "Failed to add. Invalid response.") }
            }
        }.resume()
    }
    
    @objc func promptForDeviceTransfer() {
        guard let token = tokenStore, !token.isExpired else { showErrorAlert(title: "Authorization Error", message: "Please authorize."); return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/devices")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 429 {
                        NSLog("‼️ Rate limit hit on promptForDeviceTransfer.")
                        self.isRateLimited = true // Set the flag for the persistent menu item
                        self.showRateLimitedStatusTemporarily()
                        return
                    }
                }

                guard let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let devices = json["devices"] as? [[String: Any]] else {
                    self.showErrorAlert(title: "Device Error", message: "Could not get devices. Code: \((response as? HTTPURLResponse)?.statusCode ?? 0)"); return
                }
                if devices.isEmpty { self.showErrorAlert(title: "No Devices", message: "No active Spotify devices found."); return }
                let alert = NSAlert()
                alert.messageText = "Select a Device"; alert.informativeText = "Choose a device to transfer playback to:"
                alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 24), pullsDown: false)
                devices.forEach { deviceData in
                    if let name = deviceData["name"] as? String, let id = deviceData["id"] as? String {
                        popup.addItem(withTitle: name); popup.lastItem?.representedObject = id
                    }
                }
                alert.accessoryView = popup
                if alert.runModal() == .alertFirstButtonReturn, let selectedItem = popup.selectedItem, let deviceId = selectedItem.representedObject as? String {
                    self.transferPlaybackToSelectedDevice(deviceId: deviceId, deviceName: selectedItem.title, play: true)
                }
            }
        }.resume()
    }

    func transferPlaybackToSelectedDevice(deviceId: String, deviceName: String, play: Bool) {
        guard let token = tokenStore, !token.isExpired else { showErrorAlert(title: "Authorization Error", message: "Please authorize."); return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_ids": [deviceId], "play": play])
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 429 {
                        NSLog("‼️ Rate limit hit on transferPlaybackToSelectedDevice.")
                        self.isRateLimited = true // Set the flag for the persistent menu item
                        self.showRateLimitedStatusTemporarily()
                        return
                    }
                    if httpResponse.statusCode == 204 {
                        NSLog("✅ Playback transferred to \(deviceName).")
                        self.showSuccessAlert(title: "Playback Transferred", message: "Playback transferred to \(deviceName).")
                        let deviceToSave = SpotifyDeviceStore(id: deviceId, name: deviceName); deviceToSave.save()
                        self.preferredDevice = deviceToSave
                        self.updateAllData()
                    } else { self.showErrorAlert(title: "Transfer Failed", message: "Could not transfer. Code: \(httpResponse.statusCode)") }
                } else { self.showErrorAlert(title: "Transfer Failed", message: "Could not transfer. Invalid response.") }
            }
        }.resume()
    }
    
    func showErrorAlert(title: String, message: String) { DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
            alert.alertStyle = .warning; alert.addButton(withTitle: "OK"); alert.runModal()
    }}
    func showSuccessAlert(title: String, message: String) { DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
            alert.alertStyle = .informational; alert.addButton(withTitle: "OK"); alert.runModal()
    }}
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { return false }

    // MARK: - Player Control Actions
    @objc func playPauseTapped(_ sender: Any) {
        guard case .playing(_, let context, _) = internalCurrentPlaybackState else {
            if tokenStore != nil && !(tokenStore!.isExpired) {
                 performPlayerAction(endpoint: "/me/player/play", method: "PUT")
            }
            return
        }
        let endpoint = context.isPlaying ? "/me/player/pause" : "/me/player/play"
        performPlayerAction(endpoint: endpoint, method: "PUT")
    }
    @objc func nextTrackTapped(_ sender: Any) { performPlayerAction(endpoint: "/me/player/next", method: "POST") }
    @objc func previousTrackTapped(_ sender: Any) { performPlayerAction(endpoint: "/me/player/previous", method: "POST") }
    @objc func shuffleTapped(_ sender: Any) {
        guard case .playing(_, let context, _) = internalCurrentPlaybackState else { return }
        performPlayerAction(endpoint: "/me/player/shuffle?state=\(!context.shuffleState)", method: "PUT")
    }
    @objc func repeatTapped(_ sender: Any) {
        guard case .playing(_, let context, _) = internalCurrentPlaybackState else { return }
        let nextState = context.repeatState == "off" ? "context" : (context.repeatState == "context" ? "track" : "off")
        performPlayerAction(endpoint: "/me/player/repeat?state=\(nextState)", method: "PUT")
    }
    @objc func volumeSliderDidChange(_ sender: NSSlider) {
        performPlayerAction(endpoint: "/me/player/volume?volume_percent=\(sender.integerValue)", method: "PUT", immediateUpdate: false)
    }
    // NEW: Function to show "Rate Limited" temporarily in status bar
    private func showRateLimitedStatusTemporarily() {
        DispatchQueue.main.async {
            self.rateLimitMessageTimer?.invalidate() // Invalidate any existing timer

            // Save current status bar content
            let originalImage = self.statusItem.button?.image
            let originalTitle = self.statusItem.button?.title
            let originalToolTip = self.statusItem.button?.toolTip

            // Set "Rate Limited" message
            self.statusItem.button?.image = nil
            self.statusItem.button?.title = "Rate Limited"
            self.statusItem.button?.toolTip = "Rate Limited: Please wait a moment."

            // Start timer to revert
            self.rateLimitMessageTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                // Revert to the actual state, forcing a UI update
                // This will re-evaluate internalCurrentPlaybackState and set the correct title/image
                self.updateUI(for: self.internalCurrentPlaybackState)
                self.rateLimitMessageTimer = nil
            }
        }
    }
    private func performPlayerAction(endpoint: String, method: String, body: Data? = nil, immediateUpdate: Bool = true) {
        guard let token = tokenStore?.accessToken else { NSLog("❌ Player Action: No token"); return }
        let url = URL(string: "https://api.spotify.com/v1" + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let bodyData = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            if let error = error { NSLog("❌ Player action '\(endpoint)' network error: \(error.localizedDescription)"); return }
            guard let httpResponse = response as? HTTPURLResponse else { NSLog("❌ Player action '\(endpoint)' invalid response."); return }

            if httpResponse.statusCode == 429 {
                NSLog("‼️ Rate limit hit on player action '\(endpoint)'.")
                self.isRateLimited = true // Set the flag for the persistent menu item
                DispatchQueue.main.async { self.showRateLimitedStatusTemporarily() }
                return // Return immediately after showing temporary message
            }

            if (200...299).contains(httpResponse.statusCode) {
                NSLog("✅ Player action '\(endpoint)' successful. Code: \(httpResponse.statusCode)")
                if immediateUpdate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.updateAllData() }
                }
            } else { NSLog("❌ Player action '\(endpoint)' failed. Code: \(httpResponse.statusCode)") }
        }.resume()
    }
}

// MARK: - PKCE Helper
struct PKCE {
    static func generateCodeVerifier() -> String? {
        var buffer = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else { return nil }
        return Data(buffer).base64URLEncodedString()
    }
    static func codeChallenge(for verifier: String) -> String? {
        guard let data = verifier.data(using: .utf8) else { return nil }
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64URLEncodedString()
    }
}
extension Data {
    func base64URLEncodedString() -> String {
        return self.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
