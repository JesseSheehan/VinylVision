//
//  CameraView.swift
//  VinylVision
//

import SwiftUI
import RealityKit

#if os(visionOS)
import ARKit

struct CameraView: View {
    @Environment(AppState.self) private var appState
    @State private var arSession = ARKitSession()
    @State private var worldTracking = WorldTrackingProvider()

    var body: some View {
        RealityView { content in }
        .task {
            do { try await arSession.run([worldTracking]) }
            catch { print("❌ ARKit error: \(error)") }
        }
        .overlay {
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "viewfinder.circle")
                        .font(.system(size: 64)).foregroundStyle(.blue)
                    Text("Point at album cover").font(.title).fontWeight(.semibold)
                    Text("Full camera support coming in visionOS 3.0")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(40)
                .glassBackgroundEffect()
                .padding(.bottom, 60)
            }
        }
    }
}

#else
import UIKit
import AVFoundation
import Vision

struct CameraView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var detectionState: DetectionState = .searching
    @State private var confidence: Double = 0.0
    @State private var detectedRect: CGRect = .zero
    @State private var isCapturing = false
    @State private var showRetry = false
    @State private var retryMessage = ""
    @State private var cameraKey = UUID()
    @State private var isUltraWide = false
    @State private var triggerLensToggle = false  // ← flipping this triggers the switch
    @State private var showLowConfidence = false
    @State private var lowConfidenceAlbum: Album?
    @State private var lowConfidenceOCRLines: [String] = []

    /// Below this music-confidence score, we surface the album but warn the user
    /// the match may be wrong and suggest using the Search tab instead.
    private let lowConfidenceThreshold: Double = 0.5

    var body: some View {
        ZStack {
            LiveCameraView(
                detectionState: $detectionState,
                confidence: $confidence,
                detectedRect: $detectedRect,
                isCapturing: $isCapturing,
                triggerLensToggle: $triggerLensToggle,  // ← new
                autoPhotoEnabled: appState.autoPhotoEnabled,
                onImageCaptured: { image in
                    Task { await handleCapturedImage(image) }
                }
            )
            .ignoresSafeArea()
            .id(cameraKey)

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                    }
                    .padding(.leading, 20)
                    .padding(.top, 20)

                    Spacer()

                    if appState.showAutoPhotoToggle {
                        Button { toggleAutoPhoto() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: appState.autoPhotoEnabled ? "bolt.fill" : "bolt.slash.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(appState.autoPhotoEnabled ? "AUTO" : "MANUAL")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .liquidGlass(in: Capsule(), interactive: true)
                            .shadow(color: .black.opacity(0.4), radius: 4)
                        }
                        .padding(.trailing, 20)
                        .padding(.top, 20)
                    }
                }

                Spacer()

                if detectionState == .capturing {
                    CaptureSpinnerView()
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                } else {
                    ViewfinderOverlay(detectionState: detectionState, confidence: confidence)
                }

                Spacer()

                VStack(spacing: 16) {
                    statusLabel

                    if appState.autoPhotoEnabled,
                       detectionState == .detected || detectionState == .confirming {
                        ConfidenceBar(confidence: confidence).transition(.opacity)
                    }

                    ZStack {
                        Button { isCapturing = true } label: {
                            ZStack {
                                Circle().fill(.white).frame(width: 72, height: 72)
                                Circle()
                                    .stroke(
                                        detectionState == .detected || detectionState == .confirming
                                            ? Color.green : Color.white.opacity(0.5),
                                        lineWidth: 4
                                    )
                                    .frame(width: 84, height: 84)
                            }
                        }
                        .disabled(isCapturing || showRetry)
                        .shadow(color: .black.opacity(0.3), radius: 6)

                        HStack {
                            // Home button (bottom-left)
                            Button { dismiss() } label: {
                                Image(systemName: "house.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .liquidGlass(in: Circle(), interactive: true)
                                    .shadow(color: .black.opacity(0.4), radius: 4)
                            }

                            Spacer()

                            // Lens toggle (bottom-right)
                            if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
                                Button {
                                    triggerLensToggle.toggle()
                                    isUltraWide.toggle()
                                } label: {
                                    Text(isUltraWide ? "1x" : ".5x")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .liquidGlass(in: Circle(), interactive: true)
                                        .shadow(color: .black.opacity(0.4), radius: 4)
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                    }
                }
                .padding(.bottom, 40)
            }
            .opacity(showRetry || showLowConfidence ? 0.3 : 1)

            if showRetry {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { retryCamera() }

                retryOverlay
                    .onTapGesture { /* swallow taps so backdrop doesn't dismiss */ }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if showLowConfidence, let album = lowConfidenceAlbum {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissLowConfidence() }

                lowConfidenceOverlay(for: album)
                    .onTapGesture { /* swallow taps so backdrop doesn't dismiss */ }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .statusBar(hidden: true)
        .animation(.easeInOut(duration: 0.3), value: detectionState)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: showRetry)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: showLowConfidence)
        .onChange(of: appState.currentAlbum) { _, newAlbum in
            // When an album gets set externally — e.g. user picked one from the
            // search sheet inside a retry / low-confidence overlay — dismiss the
            // camera so ContentView can surface AlbumDetailView.
            if newAlbum != nil {
                appState.isScanning = false
                dismiss()
            }
        }
    }

    private var retryOverlay: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 52))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Couldn't Identify Album")
                    .font(.title2).fontWeight(.bold)
                Text(retryMessage)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 16) {
                Button { retryCamera() } label: {
                    Label("Try Again", systemImage: "camera.fill")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .background(LinearGradient(colors: [.purple, .pink],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(Capsule())
                }
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }
            
            AlbumSearchButton(prefill: "", style: .prominent)
                .environment(appState)
        }
        .padding(32)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 10)
        .padding(.horizontal, 24)
    }

    private func retryCamera() {
        showRetry = false
        retryMessage = ""
        isCapturing = false
        detectionState = .searching
        confidence = 0
        detectedRect = .zero
        cameraKey = UUID()
    }

    private func lowConfidenceOverlay(for album: Album) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 52))
                .foregroundStyle(.yellow)

            VStack(spacing: 8) {
                Text("Is this the right album?")
                    .font(.title2).fontWeight(.bold)
                Text("We're not totally sure about this match. If it looks wrong, try the Search tab.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 12) {
                AsyncImage(url: URL(string: album.imageURL)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay(Image(systemName: "opticaldisc").foregroundStyle(.secondary))
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.subheadline).fontWeight(.semibold)
                        .lineLimit(1)
                    Text(album.artist)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(12)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 12) {
                Button { acceptLowConfidenceMatch() } label: {
                    Label("Looks Right", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LinearGradient(colors: [.purple, .pink],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(Capsule())
                }

                AlbumSearchButton(
                    prefill: "\(album.artist) \(album.name)",
                    style: .prominent,
                    suggestions: lowConfidenceOCRLines
                )
                .environment(appState)
            }
        }
        .padding(32)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 10)
        .padding(.horizontal, 24)
    }

    private func acceptLowConfidenceMatch() {
        guard let album = lowConfidenceAlbum else { return }
        appState.currentAlbum = album
        appState.addToHistory(album)
        appState.isScanning = false
        showLowConfidence = false
        lowConfidenceAlbum = nil
        dismiss()
    }

    private func toggleAutoPhoto() {
        let newValue = !appState.autoPhotoEnabled
        appState.autoPhotoEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: "autoPhotoEnabled")
        // If turning auto back on while a rect is still framed, the user expects
        // the countdown to start immediately on the next detected frame — that
        // happens naturally because resetDetection clears hasDetectedRect.
        if !newValue {
            // Turning off: stop any in-flight countdown without losing the rect view
            confidence = 0
            if detectionState == .confirming { detectionState = .detected }
        }
    }

    private func dismissLowConfidence() {
        showLowConfidence = false
        lowConfidenceAlbum = nil
        lowConfidenceOCRLines = []
        isCapturing = false
        detectionState = .searching
        confidence = 0
        detectedRect = .zero
        cameraKey = UUID()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch detectionState {
        case .searching:
            Label("Searching for album...", systemImage: "viewfinder")
                .font(.subheadline).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .liquidGlass(in: Capsule())
        case .detected:
            Label("Album detected! Hold steady...", systemImage: "checkmark.circle")
                .font(.subheadline).foregroundStyle(.green)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .liquidGlass(in: Capsule())
        case .confirming:
            Label("Locking in...", systemImage: "lock.circle")
                .font(.subheadline).foregroundStyle(.green)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .liquidGlass(in: Capsule())
        case .capturing:
            Label("Identifying album...", systemImage: "sparkles")
                .font(.subheadline).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .liquidGlass(in: Capsule())
        }
    }

    private func handleCapturedImage(_ image: UIImage) async {
        await MainActor.run {
            detectionState = .capturing
            appState.isLoadingAlbum = true
            appState.errorMessage = nil
        }
        do {
            let result = try await AlbumRecognitionService.shared.recognizeAlbum(
                from: image,
                useGemini: appState.useGeminiRecognition
            )
            await MainActor.run {
                appState.isLoadingAlbum = false

                if result.confidence < lowConfidenceThreshold {
                    // Surface the match but ask the user to confirm or search manually
                    lowConfidenceAlbum = result.album
                    lowConfidenceOCRLines = result.ocrLines
                    showLowConfidence = true
                } else {
                    appState.currentAlbum = result.album
                    appState.addToHistory(result.album)
                    appState.isScanning = false
                    dismiss()
                }
            }
        } catch {
            await MainActor.run {
                appState.isLoadingAlbum = false
                isCapturing = false
                retryMessage = error.localizedDescription
                showRetry = true
            }
        }
    }
}

// MARK: - Detection State

enum DetectionState: Equatable {
    case searching, detected, confirming, capturing
}

// MARK: - Viewfinder Overlay

struct ViewfinderOverlay: View {
    let detectionState: DetectionState
    let confidence: Double

    private var cornerColor: Color {
        switch detectionState {
        case .searching:              return .white.opacity(0.7)
        case .detected:               return .yellow
        case .confirming, .capturing: return .green
        }
    }

    private var glowColor: Color {
        switch detectionState {
        case .searching:  return .clear
        case .detected:   return .yellow.opacity(0.2)
        case .confirming: return .green.opacity(0.35)
        case .capturing:  return .green.opacity(0.5)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(glowColor)
                .frame(width: 290, height: 290)
                .animation(.easeInOut(duration: 0.4), value: detectionState)
            CornerBrackets(color: cornerColor, size: 290)
                .animation(.easeInOut(duration: 0.3), value: detectionState)
        }
    }
}

struct CornerBrackets: View {
    let color: Color
    let size: CGFloat
    let armLength: CGFloat = 28
    let lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            CornerBracket(color: color, rotation: 0,   armLength: armLength, lineWidth: lineWidth).offset(x: -size/2, y: -size/2)
            CornerBracket(color: color, rotation: 90,  armLength: armLength, lineWidth: lineWidth).offset(x:  size/2, y: -size/2)
            CornerBracket(color: color, rotation: 180, armLength: armLength, lineWidth: lineWidth).offset(x:  size/2, y:  size/2)
            CornerBracket(color: color, rotation: 270, armLength: armLength, lineWidth: lineWidth).offset(x: -size/2, y:  size/2)
        }
    }
}

struct CornerBracket: View {
    let color: Color
    let rotation: Double
    let armLength: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: armLength))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: armLength, y: 0))
        }
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        .rotationEffect(.degrees(rotation))
        .frame(width: armLength, height: armLength)
        .shadow(color: color.opacity(0.8), radius: 4)
    }
}

// MARK: - Confidence Bar

struct ConfidenceBar: View {
    let confidence: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.yellow, .green],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * confidence)
                    .animation(.linear(duration: 0.1), value: confidence)
            }
        }
        .frame(width: 200, height: 6)
        .cornerRadius(4)
    }
}

// MARK: - Capture Spinner

/// A swirling vinyl-record style spinner shown the moment the shutter fires
/// and the recognition pipeline starts running.
struct CaptureSpinnerView: View {
    @State private var isSpinning = false
    @State private var glowPulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [.purple.opacity(glowPulse ? 0.55 : 0.2), .clear],
                    center: .center, startRadius: 10, endRadius: 110
                ))
                .frame(width: 220, height: 220)
                .blur(radius: 8)

            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(
                    AngularGradient(
                        colors: [.purple, .pink, .orange, .purple],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 160, height: 160)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))

            ZStack {
                Circle().fill(.black).frame(width: 120, height: 120)
                ForEach([0.85, 0.7, 0.55, 0.4], id: \.self) { s in
                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        .frame(width: 120 * s, height: 120 * s)
                }
                Circle()
                    .fill(LinearGradient(
                        colors: [.purple, .pink],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 32, height: 32)
                Circle().fill(.black).frame(width: 6, height: 6)
            }
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
        }
        .shadow(color: .purple.opacity(0.5), radius: 20)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }
}

// MARK: - LiveCameraView

struct LiveCameraView: UIViewControllerRepresentable {
    @Binding var detectionState: DetectionState
    @Binding var confidence: Double
    @Binding var detectedRect: CGRect
    @Binding var isCapturing: Bool
    @Binding var triggerLensToggle: Bool   // ← new
    var autoPhotoEnabled: Bool
    let onImageCaptured: (UIImage) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onStateChanged      = { detectionState = $0 }
        vc.onConfidenceChanged = { confidence = $0 }
        vc.onRectChanged       = { detectedRect = $0 }
        vc.onImageCaptured     = onImageCaptured
        vc.autoPhotoEnabled    = autoPhotoEnabled
        return vc
    }

    func updateUIViewController(_ vc: CameraViewController, context: Context) {
        vc.autoPhotoEnabled = autoPhotoEnabled

        if isCapturing && vc.canCapture {
            vc.captureCurrentFrame()
        }

        // This fires every time triggerLensToggle flips
        if context.coordinator.lastLensToggle != triggerLensToggle {
            context.coordinator.lastLensToggle = triggerLensToggle
            vc.toggleCameraLens()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastLensToggle = false
    }
}

// MARK: - CameraViewController
// All stored properties live here in the class body - never in extensions

class CameraViewController: UIViewController {

    // Callbacks
    var onStateChanged: ((DetectionState) -> Void)?
    var onConfidenceChanged: ((Double) -> Void)?
    var onRectChanged: ((CGRect) -> Void)?
    var onImageCaptured: ((UIImage) -> Void)?
    var canCapture = false

    // When false, the confidence timer is suppressed and the user must tap
    // the shutter button to capture.
    var autoPhotoEnabled = true

    // Capture session
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var photoOutput: AVCapturePhotoOutput?
    
    // Camera toggle
    private var isUsingUltraWide = false

    // Detection state
    private var currentConfidence: Double = 0
    private var hasDetectedRect = false
    private var captureTimer: Timer?
    private var hasCaptured = false
    private var missedFrameCount = 0
    private let missedFrameTolerance = 8
    private var lastDetectedObservation: VNRectangleObservation?

    // Zoom state
    private var currentZoomFactor: CGFloat = 1.0
    private var lastPinchZoomFactor: CGFloat = 1.0

    // Tap-to-focus indicator, removed from the view when its animation finishes
    private weak var focusIndicator: UIView?

    // Haptics
    private let impactFeedback  = UIImpactFeedbackGenerator(style: .medium)
    private let successFeedback = UINotificationFeedbackGenerator()
    private let focusFeedback   = UIImpactFeedbackGenerator(style: .light)

    func toggleCameraLens() {
        // Check if ultra-wide is available on this device
        let ultraWideAvailable = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
        guard ultraWideAvailable else {
            print("⚠️ Ultra-wide camera not available on this device")
            return
        }

        let targetType: AVCaptureDevice.DeviceType = isUsingUltraWide
            ? .builtInWideAngleCamera      // switch back to 1x
            : .builtInUltraWideCamera      // switch to .5x

        guard let newCamera = AVCaptureDevice.default(targetType, for: .video, position: .back),
              let newInput = try? AVCaptureDeviceInput(device: newCamera),
              let session = captureSession else { return }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            isUsingUltraWide.toggle()
            // Reset zoom when switching cameras
            currentZoomFactor = 1.0
            lastPinchZoomFactor = 1.0
        }
        session.commitConfiguration()

        print(isUsingUltraWide ? "📷 Switched to ultra-wide (0.5x)" : "📷 Switched to standard (1x)")
    }

    var isUltraWideActive: Bool { isUsingUltraWide }
    
    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        checkPermissionsAndSetup()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
        captureTimer?.invalidate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - Permissions

    private func checkPermissionsAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.setupCamera() } }
            }
        default: break
        }
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let photo = AVCapturePhotoOutput()
        if session.canAddOutput(photo) { session.addOutput(photo); self.photoOutput = photo }

        let video = AVCaptureVideoDataOutput()
        video.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.detection", qos: .userInteractive))
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(video) { session.addOutput(video) }

        self.captureSession = session

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }

        setupPinchZoom()
        setupTapToFocus()

        canCapture = true
        impactFeedback.prepare()
        successFeedback.prepare()
        focusFeedback.prepare()
    }

    // MARK: - Tap to Focus

    private func setupTapToFocus() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
        view.addGestureRecognizer(tap)
    }

    @objc private func handleFocusTap(_ gesture: UITapGestureRecognizer) {
        guard let previewLayer,
              let device = (captureSession?.inputs.first as? AVCaptureDeviceInput)?.device else { return }

        let layerPoint = gesture.location(in: view)
        // Preview coordinates → the camera's own normalized coordinate space,
        // which accounts for videoGravity cropping and device orientation.
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }

            // Metering the same spot matters as much as focus here — album sleeves
            // are often shot against a much brighter or darker background.
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .continuousAutoExposure
            }

            device.unlockForConfiguration()
        } catch {
            print("❌ Focus error: \(error)")
            return
        }

        focusFeedback.impactOccurred()
        showFocusIndicator(at: layerPoint)

        // Frames go soft while the lens racks. Restart detection so an in-flight
        // countdown can't fire the shutter mid-refocus — same reasoning as pinch.
        resetDetection()
    }

    private func showFocusIndicator(at point: CGPoint) {
        focusIndicator?.removeFromSuperview()

        let box = UIView(frame: CGRect(x: 0, y: 0, width: 76, height: 76))
        box.center = point
        box.backgroundColor = .clear
        box.layer.borderColor = UIColor.systemYellow.cgColor
        box.layer.borderWidth = 1.5
        box.layer.cornerRadius = 6
        box.layer.shadowColor = UIColor.black.cgColor
        box.layer.shadowOpacity = 0.4
        box.layer.shadowRadius = 3
        box.layer.shadowOffset = .zero
        box.isUserInteractionEnabled = false
        box.alpha = 0
        box.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)

        view.addSubview(box)
        focusIndicator = box

        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            box.alpha = 1
            box.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.35, delay: 0.6, options: [.curveEaseIn]) {
                box.alpha = 0
            } completion: { _ in
                box.removeFromSuperview()
            }
        }
    }

    // MARK: - Pinch to Zoom

    private func setupPinchZoom() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let device = (captureSession?.inputs.first as? AVCaptureDeviceInput)?.device else { return }

        switch gesture.state {
        case .began:
            lastPinchZoomFactor = currentZoomFactor
            // While the user is actively framing, halt auto-capture so we don't
            // grab the photo mid-pinch. Detection resumes naturally on the next frame.
            resetDetection()

        case .changed:
            let min: CGFloat = 1.0
            let max: CGFloat = Swift.min(device.activeFormat.videoMaxZoomFactor, 5.0)
            let desired = lastPinchZoomFactor * gesture.scale

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = Swift.max(min, Swift.min(desired, max))
                currentZoomFactor = device.videoZoomFactor
                device.unlockForConfiguration()
            } catch {
                print("❌ Zoom error: \(error)")
            }

        default:
            break
        }
    }

    // MARK: - Capture

    func captureCurrentFrame() {
        guard !hasCaptured else { return }
        hasCaptured = true
        captureTimer?.invalidate()
        takePhoto()
    }

    private func takePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        photoOutput?.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Confidence Timer

    private func startConfidenceTimer() {
        captureTimer?.invalidate()
        currentConfidence = 0
        let totalTime: Double = 4.0
        let interval: Double = 0.05
        var elapsed: Double = 0

        captureTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self, !self.hasCaptured else { timer.invalidate(); return }
            elapsed += interval
            self.currentConfidence = Swift.min(elapsed / totalTime, 1.0)
            DispatchQueue.main.async {
                self.onConfidenceChanged?(self.currentConfidence)
                self.onStateChanged?(self.currentConfidence >= 0.7 ? .confirming : .detected)
            }
            if self.currentConfidence >= 1.0 {
                timer.invalidate()
                self.hasCaptured = true
                DispatchQueue.main.async {
                    self.successFeedback.notificationOccurred(.success)
                    self.onStateChanged?(.capturing)
                }
                self.takePhoto()
            }
        }
    }

    private func resetDetection() {
        captureTimer?.invalidate()
        currentConfidence = 0
        hasDetectedRect = false
        missedFrameCount = 0
        DispatchQueue.main.async {
            self.onConfidenceChanged?(0)
            self.onStateChanged?(.searching)
        }
    }
}

// MARK: - Rectangle Detection

extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !hasCaptured,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectRectanglesRequest { [weak self] request, _ in
            guard let self else { return }

            guard let results = request.results as? [VNRectangleObservation],
                  let best = results.first else {
                self.missedFrameCount += 1
                if self.missedFrameCount >= self.missedFrameTolerance && self.hasDetectedRect {
                    self.hasDetectedRect = false
                    self.resetDetection()
                }
                return
            }

            self.missedFrameCount = 0
            let area = best.boundingBox.width * best.boundingBox.height
            guard area > 0.15 else { self.missedFrameCount += 1; return }

            self.lastDetectedObservation = best

            if !self.hasDetectedRect {
                self.hasDetectedRect = true
                DispatchQueue.main.async {
                    self.impactFeedback.impactOccurred()
                    self.onStateChanged?(.detected)
                    self.onRectChanged?(best.boundingBox)
                }
                if self.autoPhotoEnabled {
                    DispatchQueue.main.async { self.startConfidenceTimer() }
                }
            }
        }

        request.minimumAspectRatio  = 0.3
        request.maximumAspectRatio  = 1.0
        request.minimumSize         = 0.12
        request.maximumObservations = 1
        request.minimumConfidence   = 0.6

        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }
}

// MARK: - Photo Capture + Crop

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let fullImage = UIImage(data: data) else { return }

        let finalImage = cropToDetectedRect(image: fullImage) ?? fullImage
        captureSession?.stopRunning()

        DispatchQueue.main.async { [weak self] in
            self?.onImageCaptured?(finalImage)
        }
    }

    private func cropToDetectedRect(image: UIImage) -> UIImage? {
        guard let observation = lastDetectedObservation,
              let cgImage = image.cgImage else { return nil }

        let W = CGFloat(cgImage.width)
        let H = CGFloat(cgImage.height)
        let bb = observation.boundingBox

        let cropX = bb.minX * W
        let cropY = (1 - bb.maxY) * H
        let cropW = bb.width  * W
        let cropH = bb.height * H
        let pad   = Swift.min(cropW, cropH) * 0.02

        let rect = CGRect(
            x: Swift.max(0, cropX - pad),
            y: Swift.max(0, cropY - pad),
            width:  Swift.min(W - cropX + pad, cropW + pad * 2),
            height: Swift.min(H - cropY + pad, cropH + pad * 2)
        )

        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
#endif
