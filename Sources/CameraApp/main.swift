import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class PreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var usesLayerMirroringFallback = false

    var mirrorsHorizontally = false {
        didSet {
            applyPreviewInversion()
        }
    }

    var flipsVertically = false {
        didSet {
            applyPreviewInversion()
        }
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return previewLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override func layout() {
        super.layout()
        layoutPreviewLayer()
    }

    private func configureLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(previewLayer)
        layoutPreviewLayer()
    }

    private func layoutPreviewLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.bounds = bounds
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        applyPreviewTransform()
        CATransaction.commit()
    }

    func applyPreviewInversion() {
        usesLayerMirroringFallback = mirrorsHorizontally

        if let connection = videoPreviewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrorsHorizontally
            usesLayerMirroringFallback = false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyPreviewTransform()
        CATransaction.commit()
    }

    private func applyPreviewTransform() {
        let xScale: CGFloat = usesLayerMirroringFallback ? -1 : 1
        let yScale: CGFloat = flipsVertically ? -1 : 1
        previewLayer.transform = CATransform3DMakeScale(xScale, yScale, 1)
    }
}

struct CameraFeatureState {
    let centerStageSupported: Bool
    let centerStageEnabled: Bool
    let centerStageActive: Bool
    let portraitEffectSupported: Bool
    let portraitEffectEnabled: Bool
    let portraitEffectActive: Bool

    static let unavailable = CameraFeatureState(
        centerStageSupported: false,
        centerStageEnabled: false,
        centerStageActive: false,
        portraitEffectSupported: false,
        portraitEffectEnabled: false,
        portraitEffectActive: false
    )
}

final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "CameraApp.session")
    private let photoOutput = AVCapturePhotoOutput()
    private weak var previewView: PreviewView?
    private weak var window: NSWindow?
    private var videoDevice: AVCaptureDevice?
    private var capturesMirrored = false
    private var capturesFlipped = false
    private var isConfigured = false

    var onStatusChange: ((String, Bool) -> Void)?
    var onFeatureStateChange: ((CameraFeatureState) -> Void)?

    func start(previewView: PreviewView, window: NSWindow) {
        self.previewView = previewView
        self.window = window
        previewView.videoPreviewLayer.session = session

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            onStatusChange?("Waiting for camera permission...", false)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.onStatusChange?("Camera access denied. Enable it in System Settings.", false)
                        self.onFeatureStateChange?(.unavailable)
                    }
                }
            }
        case .denied, .restricted:
            onStatusChange?("Camera access denied. Enable it in System Settings.", false)
            onFeatureStateChange?(.unavailable)
        @unknown default:
            onStatusChange?("Camera access is unavailable on this Mac.", false)
            onFeatureStateChange?(.unavailable)
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func setCenterStageEnabled(_ isEnabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let videoDevice = self.videoDevice, videoDevice.activeFormat.isCenterStageSupported else {
                DispatchQueue.main.async {
                    self.onStatusChange?("Center Stage is unavailable for this camera.", self.session.isRunning)
                    self.publishFeatureState()
                }
                return
            }

            AVCaptureDevice.centerStageControlMode = .cooperative
            AVCaptureDevice.isCenterStageEnabled = isEnabled

            DispatchQueue.main.async {
                self.onStatusChange?(isEnabled ? "Center Stage enabled" : "Center Stage disabled", self.session.isRunning)
                self.publishFeatureState()
            }
        }
    }

    func showPortraitEffectControls() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let isSupported = self.videoDevice?.activeFormat.isPortraitEffectSupported == true

            DispatchQueue.main.async {
                guard isSupported else {
                    self.onStatusChange?("Background Blur is unavailable for this camera.", self.session.isRunning)
                    self.publishFeatureState()
                    return
                }

                AVCaptureDevice.showSystemUserInterface(.videoEffects)
                self.onStatusChange?("Use Video Effects to toggle Background Blur.", self.session.isRunning)
                self.publishFeatureState()
            }
        }
    }

    func setCaptureInversion(mirrorsHorizontally: Bool, flipsVertically: Bool) {
        sessionQueue.async { [weak self] in
            self?.capturesMirrored = mirrorsHorizontally
            self?.capturesFlipped = flipsVertically
        }
    }

    func refreshFeatureState() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.publishFeatureState()
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    self.onStatusChange?("Camera is not running.", false)
                }
                return
            }

            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            self.photoOutput.capturePhoto(with: settings, delegate: self)

            DispatchQueue.main.async {
                self.onStatusChange?("Capturing photo...", false)
            }
        }
    }

    private func configureAndStart() {
        onStatusChange?("Starting camera...", false)

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                if !self.isConfigured {
                    try self.configureSession()
                    self.isConfigured = true
                }

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                DispatchQueue.main.async {
                    self.previewView?.applyPreviewInversion()
                    self.onStatusChange?("Camera ready", true)
                    self.publishFeatureState()
                }
            } catch {
                DispatchQueue.main.async {
                    self.onStatusChange?("Camera error: \(error.localizedDescription)", false)
                    self.onFeatureStateChange?(.unavailable)
                }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }

        try configurePreferredFormat(for: camera)

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(cameraInput)
        videoDevice = camera

        guard session.canAddOutput(photoOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(photoOutput)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async {
                self.onStatusChange?("Capture failed: \(error.localizedDescription)", true)
            }
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.onStatusChange?("Capture failed: no image data.", true)
            }
            return
        }

        let outputData = transformedPhotoData(from: data)
        DispatchQueue.main.async {
            self.savePhoto(outputData)
        }
    }

    private func configurePreferredFormat(for camera: AVCaptureDevice) throws {
        guard !camera.activeFormat.isCenterStageSupported || !camera.activeFormat.isPortraitEffectSupported else {
            return
        }

        let formats = camera.formats
        let preferredFormat = formats.first(where: { $0.isCenterStageSupported && $0.isPortraitEffectSupported })
            ?? formats.first(where: { $0.isCenterStageSupported })
            ?? formats.first(where: { $0.isPortraitEffectSupported })

        guard let preferredFormat else {
            return
        }

        try camera.lockForConfiguration()
        camera.activeFormat = preferredFormat
        camera.unlockForConfiguration()
    }

    private func transformedPhotoData(from data: Data) -> Data {
        guard capturesMirrored || capturesFlipped else {
            return data
        }

        guard
            let image = NSImage(data: data),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return data
        }

        let width = cgImage.width
        let height = cgImage.height
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 32
            ),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return data
        }

        let context = graphicsContext.cgContext
        context.interpolationQuality = .high
        context.translateBy(
            x: capturesMirrored ? CGFloat(width) : 0,
            y: capturesFlipped ? CGFloat(height) : 0
        )
        context.scaleBy(
            x: capturesMirrored ? -1 : 1,
            y: capturesFlipped ? -1 : 1
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.92]
        ) ?? data
    }

    private func savePhoto(_ data: Data) {
        let panel = NSSavePanel()
        panel.title = "Save Photo"
        panel.nameFieldStringValue = "Camera \(Self.timestamp()).jpg"
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                self?.onStatusChange?("Camera ready", true)
                return
            }

            do {
                try data.write(to: url, options: .atomic)
                self?.onStatusChange?("Saved \(url.lastPathComponent)", true)
            } catch {
                self?.onStatusChange?("Save failed: \(error.localizedDescription)", true)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    private func publishFeatureState() {
        guard let videoDevice else {
            onFeatureStateChange?(.unavailable)
            return
        }

        let activeFormat = videoDevice.activeFormat
        onFeatureStateChange?(
            CameraFeatureState(
                centerStageSupported: activeFormat.isCenterStageSupported,
                centerStageEnabled: AVCaptureDevice.isCenterStageEnabled,
                centerStageActive: videoDevice.isCenterStageActive,
                portraitEffectSupported: activeFormat.isPortraitEffectSupported,
                portraitEffectEnabled: AVCaptureDevice.isPortraitEffectEnabled,
                portraitEffectActive: videoDevice.isPortraitEffectActive
            )
        )
    }

    private enum CameraError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera:
                return "No camera was found."
            case .cannotAddInput:
                return "The selected camera cannot be used."
            case .cannotAddOutput:
                return "Photo capture could not be configured."
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let previewView = PreviewView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "Starting camera...")
    private let captureButton = NSButton(title: "Capture", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Open Camera Settings", target: nil, action: nil)
    private let centerStageButton = NSButton(checkboxWithTitle: "Center Stage", target: nil, action: nil)
    private let portraitEffectButton = NSButton(checkboxWithTitle: "Background Blur", target: nil, action: nil)
    private let mirrorButton = NSButton(checkboxWithTitle: "Mirror", target: nil, action: nil)
    private let flipButton = NSButton(checkboxWithTitle: "Flip", target: nil, action: nil)
    private let cameraController = CameraController()
    private var featureRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        cameraController.onStatusChange = { [weak self] message, canCapture in
            self?.updateStatus(message, canCapture: canCapture)
        }
        cameraController.onFeatureStateChange = { [weak self] featureState in
            self?.updateFeatureControls(featureState)
        }

        cameraController.start(previewView: previewView, window: window)
        featureRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.cameraController.refreshFeatureState()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        featureRefreshTimer?.invalidate()
        cameraController.stop()
    }

    private func buildWindow() {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 0

        let controls = NSVisualEffectView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.material = .underWindowBackground
        controls.blendingMode = .withinWindow
        controls.state = .active

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        centerStageButton.translatesAutoresizingMaskIntoConstraints = false
        centerStageButton.target = self
        centerStageButton.action = #selector(toggleCenterStage)
        centerStageButton.isEnabled = false
        centerStageButton.toolTip = "Center Stage is unavailable for this camera."

        portraitEffectButton.translatesAutoresizingMaskIntoConstraints = false
        portraitEffectButton.target = self
        portraitEffectButton.action = #selector(togglePortraitEffect)
        portraitEffectButton.isEnabled = false
        portraitEffectButton.toolTip = "Background Blur is unavailable for this camera."

        mirrorButton.translatesAutoresizingMaskIntoConstraints = false
        mirrorButton.target = self
        mirrorButton.action = #selector(togglePreviewMirror)
        mirrorButton.toolTip = "Mirror the camera preview horizontally."

        flipButton.translatesAutoresizingMaskIntoConstraints = false
        flipButton.target = self
        flipButton.action = #selector(togglePreviewFlip)
        flipButton.toolTip = "Flip the camera preview vertically."

        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.target = self
        captureButton.action = #selector(capturePhoto)
        captureButton.bezelStyle = .rounded
        captureButton.keyEquivalent = "\r"
        captureButton.isEnabled = false

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.target = self
        settingsButton.action = #selector(openCameraSettings)
        settingsButton.bezelStyle = .rounded
        settingsButton.isHidden = true

        let featureStack = NSStackView(views: [centerStageButton, portraitEffectButton, mirrorButton, flipButton])
        featureStack.translatesAutoresizingMaskIntoConstraints = false
        featureStack.orientation = .horizontal
        featureStack.alignment = .centerY
        featureStack.spacing = 14
        featureStack.setContentHuggingPriority(.required, for: .horizontal)

        let statusStack = NSStackView(views: [statusLabel, featureStack])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 8
        statusStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actionStack = NSStackView(views: [settingsButton, captureButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 12
        actionStack.setContentHuggingPriority(.required, for: .horizontal)

        contentView.addSubview(previewView)
        contentView.addSubview(controls)
        controls.addSubview(statusStack)
        controls.addSubview(actionStack)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: contentView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: controls.topAnchor),

            controls.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 96),

            statusStack.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 20),
            statusStack.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -16),

            actionStack.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            actionStack.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -20),
            captureButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            captureButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Camera"
        window.minSize = NSSize(width: 720, height: 420)
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About Camera", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Camera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let captureItem = NSMenuItem(title: "Capture Photo", action: #selector(capturePhoto), keyEquivalent: "\r")
        captureItem.target = self
        fileMenu.addItem(captureItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func updateStatus(_ message: String, canCapture: Bool) {
        statusLabel.stringValue = message
        captureButton.isEnabled = canCapture
        settingsButton.isHidden = !message.localizedCaseInsensitiveContains("denied")
    }

    private func updateFeatureControls(_ featureState: CameraFeatureState) {
        centerStageButton.isEnabled = featureState.centerStageSupported
        centerStageButton.state = featureState.centerStageEnabled ? .on : .off
        centerStageButton.toolTip = featureState.centerStageSupported
            ? (featureState.centerStageActive ? "Center Stage is active." : "Toggle Center Stage for the camera preview.")
            : "Center Stage is unavailable for this camera."

        portraitEffectButton.isEnabled = featureState.portraitEffectSupported
        portraitEffectButton.state = featureState.portraitEffectEnabled ? .on : .off
        portraitEffectButton.toolTip = featureState.portraitEffectSupported
            ? (featureState.portraitEffectActive ? "Background Blur is active." : "Open Video Effects to toggle Background Blur.")
            : "Background Blur is unavailable for this camera."
    }

    @objc private func capturePhoto() {
        cameraController.capturePhoto()
    }

    @objc private func toggleCenterStage() {
        cameraController.setCenterStageEnabled(centerStageButton.state == .on)
    }

    @objc private func togglePortraitEffect() {
        portraitEffectButton.state = AVCaptureDevice.isPortraitEffectEnabled ? .on : .off
        cameraController.showPortraitEffectControls()
    }

    @objc private func togglePreviewMirror() {
        previewView.mirrorsHorizontally = mirrorButton.state == .on
        cameraController.setCaptureInversion(
            mirrorsHorizontally: previewView.mirrorsHorizontally,
            flipsVertically: previewView.flipsVertically
        )
    }

    @objc private func togglePreviewFlip() {
        previewView.flipsVertically = flipButton.state == .on
        cameraController.setCaptureInversion(
            mirrorsHorizontally: previewView.mirrorsHorizontally,
            flipsVertically: previewView.flipsVertically
        )
    }

    @objc private func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Camera",
            .applicationVersion: "1.0"
        ])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
