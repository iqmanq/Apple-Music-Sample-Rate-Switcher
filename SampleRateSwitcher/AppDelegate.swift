//
//  AppDelegate.swift
//  SampleRateSwitcher
//
//  Created by Iqraa Manuel on 5/21/25.
//

import Foundation
import SQLite3
import AppKit
import CoreAudio

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var currentSampleRate: Double = 44100.0
    var isFavorited: Bool? = nil
    var lastXMLModifiedDate: Date? = nil
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = getCurrentAppleMusicTrackDisplayText()
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "🎶 Override Sample Rate", action: nil, keyEquivalent: ""))
        
        let overrideMenu = NSMenu()
        [44100, 48000, 88200, 96000, 176400, 192000].forEach { rate in
            let item = NSMenuItem(
                title: "\(rate / 1000) kHz",
                action: #selector(setSampleRateFromMenu(_:)),
                keyEquivalent: ""
            )
            item.representedObject = rate
            overrideMenu.addItem(item)
        }
        let overrideItem = menu.item(at: 0)
        overrideItem?.submenu = overrideMenu
        menu.addItem(NSMenuItem(title: "⭐️ Toggle Favorite", action: #selector(toggleFavoriteStatus), keyEquivalent: "f"))
        menu.addItem(NSMenuItem(title: "💾 Tag Current Album", action: #selector(tagCurrentAlbum), keyEquivalent: "a"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        
        // (Removed updateFavoriteTrackList and timer for it)
        
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.autoUpdateSampleRate()
            self.checkIfCurrentSongIsFavorited()
            if let button = self.statusItem.button {
                button.title = self.getCurrentAppleMusicTrackDisplayText()
            }
        }

        // Polling timer for Library.xml changes
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            let xmlURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/Library.xml")
            
            if let attrs = try? FileManager.default.attributesOfItem(atPath: xmlURL.path),
               let modifiedDate = attrs[.modificationDate] as? Date {
                if self.lastXMLModifiedDate == nil || self.lastXMLModifiedDate! < modifiedDate {
                    self.lastXMLModifiedDate = modifiedDate
                    print("📄 Detected updated Library.xml via polling — refreshing favorites.")
                    self.refreshFavoritesFromXML()
                }
            }
        }
    }
    func getCurrentAppleMusicTrackDisplayText() -> String {
        let track = getCurrentAppleMusicTrack()
        guard track != "None" && track != "Error" && track != "Not Running" else {
            return "🎵 No Song"
        }
        
        let star = isFavorited == true ? "⭐️" : ""
        return "🎵 \(track) — \(Int(currentSampleRate / 1000)) kHz \(star)"
    }
    
    @objc func setSampleRateFromMenu(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Int else { return }
        setOutputDeviceSampleRate(to: Double(rate))
        let track = getCurrentAppleMusicTrack()
        saveOverrideSampleRate(for: track, rate: rate)
        print("🔧 Overridden sample rate to \(rate) Hz for \(track)")
        if let button = statusItem.button {
            button.title = getCurrentAppleMusicTrackDisplayText()
        }
    }
    
    @objc func tagCurrentAlbum() {
        let currentTrack = getCurrentAppleMusicTrack()
        guard currentTrack != "Error", currentTrack != "None", currentTrack != "Not Running" else {
            print("No valid track playing.")
            return
        }
        
        let parts = currentTrack.components(separatedBy: " - ")
        let title = parts.first ?? currentTrack
        let artist = parts.count > 1 ? parts.last! : ""
        
        let albumScript = """
        tell application "Music"
            if it is running and player state is playing then
                return album of current track
            else
                return "Unknown Album"
            end if
        end tell
        """
        
        var errorDict: NSDictionary?
        var albumName = "Unknown Album"
        if let albumScriptObj = NSAppleScript(source: albumScript) {
            if let output = albumScriptObj.executeAndReturnError(&errorDict).stringValue {
                albumName = output
            }
        }
        
        let albumKey = "\(artist) - \(albumName)"
        
        let alert = NSAlert()
        alert.messageText = "Set Album Sample Rate"
        alert.informativeText = "Choose a sample rate for: \(albumKey)"
        alert.alertStyle = .informational
        
        let sampleRates = [44100, 48000, 88200, 96000, 176400, 192000]
        sampleRates.forEach { rate in
            alert.addButton(withTitle: "\(rate / 1000) kHz")
        }
        
        let response = alert.runModal()
        let selectedIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard selectedIndex >= 0 && selectedIndex < sampleRates.count else { return }
        
        let selectedRate = sampleRates[selectedIndex]
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AlbumSampleRateOverrides.txt")
        
        var overrides: [String: Int] = [:]
        if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
            contents.components(separatedBy: .newlines).forEach { line in
                let parts = line.components(separatedBy: " = ")
                if parts.count == 2, let r = Int(parts[1]) {
                    overrides[parts[0]] = r
                }
            }
        }
        
        overrides[albumKey] = selectedRate
        let updated = overrides.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: "\n")
        try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
        
        print("📀 Tagged album: \(albumKey) with \(selectedRate) Hz")
        
        let current = getCurrentAppleMusicTrack()
        if current.contains(title) && current.contains(artist) {
            setOutputDeviceSampleRate(to: Double(selectedRate))
            if let button = statusItem.button {
                button.title = getCurrentAppleMusicTrackDisplayText()
            }
        }
    }
    
    @objc func printCurrentTrack() {
        let track = getCurrentAppleMusicTrack()
        print("Current track: \(track)")
    }
    
    @objc func toggleFavoriteStatus() {
        let currentTrack = getCurrentAppleMusicTrack()
        guard currentTrack != "None" && currentTrack != "Error" && currentTrack != "Not Running" else {
            print("No track available to toggle favorite status.")
            return
        }
        
        let currentlyFavorited = isFavorited == true
        let newStatus = currentlyFavorited ? "false" : "true"
        
        let script = """
        tell application "Music"
            if it is running and player state is playing then
                set favorited of current track to \(newStatus)
            end if
        end tell
        """
        
        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&errorDict)
            if errorDict == nil {
                print("⭐️ Toggled favorite status for current track: \(currentTrack) → \(newStatus)")
                // Update the FavoriteTracks.txt manually
                let fileURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop/FavoriteTracks.txt")
                
                var favorites: [String] = []
                if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
                    favorites = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
                }
                
                if currentlyFavorited {
                    favorites.removeAll { $0 == currentTrack }
                } else {
                    favorites.append(currentTrack)
                }
                
                let updated = favorites.sorted().joined(separator: "\n")
                try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
                self.checkIfCurrentSongIsFavorited()
            } else {
                print("❌ Failed to toggle favorite: \(errorDict ?? [:])")
            }
        }
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(self)
    }
    
    func getCurrentAppleMusicTrack() -> String {
        let script = """
        tell application "Music"
            if it is running and player state is playing then
                set trackName to name of current track
                set artistName to artist of current track
                return trackName & " - " & artistName
            else
                return "None"
            end if
        end tell
        """
        
        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            if let output = appleScript.executeAndReturnError(&errorDict).stringValue {
                return output
            } else {
                print("🎧 AppleScript Error:\n\(errorDict ?? [:])")
                return "Error"
            }
        }
        return "Error"
    }
    @objc func autoUpdateSampleRate() {
        let currentTrack = getCurrentAppleMusicTrack()
        print("Auto-checking track: \(currentTrack)")
        
        guard currentTrack != "Error", currentTrack != "None", currentTrack != "Not Running" else {
            print("Skipping track update due to invalid state.")
            return
        }
        
        let parts = currentTrack.components(separatedBy: " - ")
        _ = parts.first ?? currentTrack
        let artist = parts.count > 1 ? parts.last! : ""
        
        let albumScript = """
        tell application "Music"
            if it is running and player state is playing then
                return album of current track
            else
                return "Unknown Album"
            end if
        end tell
        """
        
        var errorDict: NSDictionary?
        var albumName = "Unknown Album"
        if let albumScriptObj = NSAppleScript(source: albumScript) {
            if let output = albumScriptObj.executeAndReturnError(&errorDict).stringValue {
                albumName = output
            }
        }
        
        let albumKey = "\(artist) - \(albumName)"
        
        updateAlbumListIfNeeded(for: albumKey)
        
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/ManualSampleRateOverrides.txt")
        
        var manualRate: Int?
        if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
            contents.components(separatedBy: .newlines).forEach { line in
                let parts = line.components(separatedBy: " = ")
                if parts.count == 2, parts[0] == currentTrack, let r = Int(parts[1]) {
                    manualRate = r
                }
            }
        }
        
        if let manualRate = manualRate {
            setOutputDeviceSampleRate(to: Double(manualRate))
            if let button = self.statusItem.button {
                button.title = self.getCurrentAppleMusicTrackDisplayText()
            }
            return
        }
        
        // Check album-based override
        let albumOverrideFileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AlbumSampleRateOverrides.txt")
        
        if let contents = try? String(contentsOf: albumOverrideFileURL, encoding: .utf8) {
            let albumOverrides = contents.components(separatedBy: .newlines)
            for line in albumOverrides {
                let parts = line.components(separatedBy: " = ")
                if parts.count == 2, parts[0] == albumKey, let r = Int(parts[1]) {
                    setOutputDeviceSampleRate(to: Double(r))
                    if let button = self.statusItem.button {
                        button.title = self.getCurrentAppleMusicTrackDisplayText()
                    }
                    return
                }
            }
        }
        
        // Default sample rate
        setOutputDeviceSampleRate(to: 44100.0)
        if let button = self.statusItem.button {
            button.title = self.getCurrentAppleMusicTrackDisplayText()
        }
    }
    // Helper to save override sample rates by song title
    func saveOverrideSampleRate(for track: String, rate: Int) {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/ManualSampleRateOverrides.txt")
        
        var overrides: [String: Int] = [:]
        if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
            contents.components(separatedBy: .newlines).forEach { line in
                let parts = line.components(separatedBy: " = ")
                if parts.count == 2, let r = Int(parts[1]) {
                    overrides[parts[0]] = r
                }
            }
        }
        
        overrides[track] = rate
        
        let updated = overrides.map { "\($0.key) = \($0.value)" }
            .sorted()
            .joined(separator: "\n")
        
        try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    func setOutputDeviceSampleRate(to sampleRate: Double) {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain // Use Main instead of deprecated Master
        )
        
        var dataSize = UInt32(MemoryLayout.size(ofValue: defaultOutputDeviceID))
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &defaultOutputDeviceID
        )
        
        if status != noErr {
            print("Error getting default output device.")
            return
        }
        
        var streamFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout.size(ofValue: streamFormat))
        
        propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let getStatus = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            &formatSize,
            &streamFormat
        )
        
        if getStatus != noErr {
            print("Error getting stream format.")
            return
        }
        
        streamFormat.mSampleRate = sampleRate
        
        let setStatus = AudioObjectSetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            formatSize,
            &streamFormat
        )
        
        if setStatus != noErr {
            print("Failed to set sample rate.")
        } else {
            print("Sample rate set to \(sampleRate) Hz.")
            self.currentSampleRate = sampleRate
        }
    }
    // Helper to check if current song is favorited using pre-saved file
    func checkIfCurrentSongIsFavorited() {
        let currentTrack = getCurrentAppleMusicTrack()
        guard currentTrack != "None", currentTrack != "Error", currentTrack != "Not Running" else {
            isFavorited = nil
            return
        }
        
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/FavoriteTracks.txt")
        
        if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
            let favorites = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
            isFavorited = favorites.contains(currentTrack)
        } else {
            isFavorited = nil
        }
        
        print("⭐ Favorite status check → \(self.isFavorited.debugDescription)")
        if let button = self.statusItem.button {
            button.title = self.getCurrentAppleMusicTrackDisplayText()
        }
    }
    @objc func refreshFavoritesFromXML() {
        let xmlURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Library.xml")
        let outputURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/FavoriteTracks.txt")

        var favoriteTracks: [String] = []

        if let xmlData = try? Data(contentsOf: xmlURL),
           let xml = try? XMLDocument(data: xmlData, options: .documentTidyXML) {
            let dictNodes = try? xml.nodes(forXPath: "//dict")
            dictNodes?.forEach { node in
                let dict = node
                guard let children = dict.children else { return }

                var nameValue: String?
                var artistValue: String?
                var loved = false

                for (index, child) in children.enumerated() {
                    if child.name == "key", let key = child.stringValue {
                        if key == "Name", index + 1 < children.count {
                            nameValue = children[index + 1].stringValue
                        }
                        if key == "Artist", index + 1 < children.count {
                            artistValue = children[index + 1].stringValue
                        }
                        if key == "Loved", index + 1 < children.count {
                            let nextNode = children[index + 1]
                            if nextNode.name == "true" {
                                loved = true
                            }
                        }
                    }
                }

                if loved, let name = nameValue, let artist = artistValue {
                    let track = "\(name) - \(artist)"
                    favoriteTracks.append(track)
                }
            }
        }

        try? favoriteTracks.sorted().joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        print("📄 Refreshed favorites from XML: \(favoriteTracks.count) tracks updated.")
        self.checkIfCurrentSongIsFavorited()
    }
}

    // Adds albumKey to AlbumSampleRateOverrides.txt if not already present
    func updateAlbumListIfNeeded(for albumKey: String) {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AlbumSampleRateOverrides.txt")

        if let contents = try? String(contentsOf: fileURL, encoding: .utf8) {
            let existingAlbums = contents.components(separatedBy: .newlines).compactMap {
                $0.components(separatedBy: " = ").first
            }
            if !existingAlbums.contains(albumKey) {
                print("🔖 Added new album to album list: \(albumKey)")
                var newContents = contents
                if !contents.hasSuffix("\n") {
                    newContents += "\n"
                }
                newContents += "\(albumKey) = 44100\n"
                try? newContents.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } else {
            // File doesn't exist, create it with this album
            let initial = "\(albumKey) = 44100\n"
            try? initial.write(to: fileURL, atomically: true, encoding: .utf8)
            print("🔖 Created album override file with: \(albumKey)")
        }
    }
