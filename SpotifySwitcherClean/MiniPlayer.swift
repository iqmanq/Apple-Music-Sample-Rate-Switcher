import Cocoa

class MiniPlayerView: NSView {

    // MARK: - Properties
    let previousButton = NSButton()
    let playPauseButton = NSButton()
    let nextButton = NSButton()
    
    let shuffleButton = NSButton()
    let repeatButton = NSButton()
    let likeButton = NSButton()
    
    let volumeSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)

    weak var appDelegate: AppDelegate?

    // MARK: - Initialization
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        setupLayout()
        update(isPlaying: false, shuffleState: false, repeatState: "off", isLiked: false, volume: 50)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup Methods
    private func setupViews() {
        configureButton(previousButton, title: "Previous", sfSymbolName: "backward.fill", action: #selector(AppDelegate.previousTrackTapped))
        configureButton(playPauseButton, title: "Play/Pause", sfSymbolName: "play.fill", action: #selector(AppDelegate.playPauseTapped))
        configureButton(nextButton, title: "Next", sfSymbolName: "forward.fill", action: #selector(AppDelegate.nextTrackTapped))
        
        configureButton(shuffleButton, title: "Shuffle", sfSymbolName: "shuffle", action: #selector(AppDelegate.shuffleTapped))
        configureButton(repeatButton, title: "Repeat", sfSymbolName: "repeat", action: #selector(AppDelegate.repeatTapped))
        configureButton(likeButton, title: "Like", sfSymbolName: "heart", action: #selector(AppDelegate.toggleLikeStatus))

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged(_:))
        volumeSlider.sliderType = .linear
        volumeSlider.controlSize = .small
        volumeSlider.toolTip = "Adjust Volume"
        volumeSlider.isEnabled = true
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupLayout() {
        // --- Row 1: All Control Buttons ---
        let allControlsStack = NSStackView(views: [
            previousButton, playPauseButton, nextButton,
            shuffleButton, repeatButton, likeButton
        ])
        allControlsStack.orientation = .horizontal
        allControlsStack.spacing = 8 // Adjust spacing between buttons
        allControlsStack.distribution = .fillEqually // All 6 buttons get equal width
        allControlsStack.alignment = .centerY
        allControlsStack.translatesAutoresizingMaskIntoConstraints = false

        // --- Main Vertical Stack ---
        // This stack will contain the button row and the volume slider.
        // It will be pinned to the edges of the MiniPlayerView.
        let mainVerticalStack = NSStackView(views: [allControlsStack, volumeSlider])
        mainVerticalStack.orientation = .vertical
        mainVerticalStack.spacing = 8 // Space between button row and volume slider
        mainVerticalStack.alignment = .centerX // Center children if they are narrower (won't happen with width constraints)
        mainVerticalStack.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(mainVerticalStack)

        NSLayoutConstraint.activate([
            // Pin mainVerticalStack to the edges of MiniPlayerView with padding
            mainVerticalStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mainVerticalStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            mainVerticalStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            mainVerticalStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            // Make the horizontal button stack (allControlsStack) take the full width of mainVerticalStack
            allControlsStack.widthAnchor.constraint(equalTo: mainVerticalStack.widthAnchor),

            // Make the volumeSlider take the full width of mainVerticalStack
            volumeSlider.widthAnchor.constraint(equalTo: mainVerticalStack.widthAnchor),
        ])
    }

    private func configureButton(_ button: NSButton, title: String, sfSymbolName: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title
        button.target = appDelegate
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        
        if let symbolImage = NSImage(systemSymbolName: sfSymbolName, accessibilityDescription: title) {
            let templateImage = symbolImage.copy() as! NSImage
            templateImage.isTemplate = true
            button.image = templateImage
        }
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        // Width will be handled by .fillEqually in allControlsStack
        button.contentTintColor = NSColor.white
    }
    
    @objc private func volumeSliderChanged(_ sender: NSSlider) {
        appDelegate?.volumeSliderDidChange(sender)
    }
    
    func update(isPlaying: Bool, shuffleState: Bool, repeatState: String, isLiked: Bool, volume: Int) {
        let playPauseSymbolName = isPlaying ? "pause.fill" : "play.fill"
        if let symbolImage = NSImage(systemSymbolName: playPauseSymbolName, accessibilityDescription: isPlaying ? "Pause" : "Play") {
            let templateImage = symbolImage.copy() as! NSImage
            templateImage.isTemplate = true
            playPauseButton.image = templateImage
        }
        playPauseButton.contentTintColor = NSColor.white

        shuffleButton.contentTintColor = shuffleState ? NSColor.systemGreen : NSColor.white
        
        let repeatSymbolName = repeatState == "track" ? "repeat.1" : "repeat"
        if let symbolImage = NSImage(systemSymbolName: repeatSymbolName, accessibilityDescription: "Repeat") {
             let templateImage = symbolImage.copy() as! NSImage
            templateImage.isTemplate = true
            repeatButton.image = templateImage
        }
        repeatButton.contentTintColor = (repeatState == "off") ? NSColor.white : NSColor.systemGreen
        
        let likeSymbolName = isLiked ? "heart.fill" : "heart"
        if let symbolImage = NSImage(systemSymbolName: likeSymbolName, accessibilityDescription: isLiked ? "Unlike" : "Like") {
            let templateImage = symbolImage.copy() as! NSImage
            templateImage.isTemplate = true
            likeButton.image = templateImage
        }
        likeButton.contentTintColor = isLiked ? NSColor.systemGreen : NSColor.white
        likeButton.toolTip = isLiked ? "Unlike" : "Like"

        if !volumeSlider.isHighlighted {
             volumeSlider.integerValue = volume
        }
    }
}
