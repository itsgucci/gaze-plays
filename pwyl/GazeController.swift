//
//  GazeController.swift
//  pwyl
//
//  Created by Eric Weinert on 8/9/25.
//

import Foundation
import AVFoundation
import Vision

final class GazeController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum State { case idle, looking, away }

    // Camera + Vision
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "lookpause.camera")
    private let rectanglesRequest = VNDetectFaceRectanglesRequest()
    private let landmarksRequest = VNDetectFaceLandmarksRequest()
    // Frame processing throttle
    private var lastProcessedAt: Date = .distantPast
    private let minProcessInterval: TimeInterval = 0.10

    // Smoothing / hysteresis
    private var lastLookingFlip = Date.distantPast
    private var lastFaceSeen = Date.distantPast
    private var looking = false
    private let debounceOn: TimeInterval = 0.5   // need 0.5s of “looking”
    private let debounceOff: TimeInterval = 1.2  // need 1.2s of “away”
    var earOpenThreshold: Double = 0.17
    var pitchDownThreshold: Double = -0.10        // radians; more negative => looking down

    // External control
    var isEnabled: Bool = true { didSet { if !isEnabled { setLooking(false, force: true) }; onEnabledChanged?(isEnabled) } }
    var onEnabledChanged: ((Bool)->Void)?
    var onStateChanged: ((State)->Void)?
    var onDebug: ((String)->Void)?

    private let youtube = YouTubeController()

    override init() {
        super.init()
        youtube.onDebug = { [weak self] message in
            self?.onDebug?(message)
        }
    }

    func start() {
        // Prefer the latest landmarks revision available to improve landmark quality
        if let latest = VNDetectFaceLandmarksRequest.supportedRevisions.last {
            landmarksRequest.revision = latest
        }
        guard setupSession() else { return }
        session.startRunning()
        onStateChanged?(.idle)
        startWatchdog()
    }

    func primeAutomationPermissions() {
        youtube.primeAutomationPermissions()
    }

    private func setupSession() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified),
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else { return false }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        session.commitConfiguration()
        return true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isEnabled, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        if now.timeIntervalSince(lastProcessedAt) < minProcessInterval { return }
        lastProcessedAt = now
        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up, options: [:])
        do {
            try handler.perform([rectanglesRequest])
        } catch {
            return
        }
        guard let baseFace = rectanglesRequest.results?.first else {
            evaluateLooking(false)
            onDebug?("face: false\nface&&facing&&down: false")
            return
        }

        landmarksRequest.inputFaceObservations = [baseFace]
        do {
            try handler.perform([landmarksRequest])
        } catch {
            evaluateLooking(false)
            onDebug?("face: yes | landmarks: error")
            return
        }
        guard let face = landmarksRequest.results?.first else {
            evaluateLooking(false)
            onDebug?("face: yes | landmarks: none")
            return
        }
        lastFaceSeen = Date()

        let facing = headLikelyFacingCamera(face)
        let (vertical, verticalSource) = computeVerticalMetric(face)
        let lookingDown = vertical > pitchDownThreshold

        let faceFacingDown = true && facing && lookingDown
        evaluateLooking(faceFacingDown)

        let yaw = face.yaw?.doubleValue
        let roll = face.roll?.doubleValue
        let dbg = "face: true | facing: \(facing) | down: \(lookingDown) | vert(\(verticalSource)): \(vertical) thr \(pitchDownThreshold) | yaw: \(yaw ?? .nan) | roll: \(roll ?? .nan)\nface&&facing&&down: \(faceFacingDown)"
        onDebug?(dbg)
    }

    private func computeVerticalMetric(_ face: VNFaceObservation) -> (value: Double, source: String) {
        if let p = face.pitch?.doubleValue {
            return (p, "pitch")
        }
        // Fallback: relative vertical offset of nose center to eye center
        guard let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye else {
            return (0, "fallback-none")
        }
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = (0..<region.pointCount).map { region.normalizedPoints[$0] }
            guard !pts.isEmpty else { return .zero }
            let sx = pts.reduce(0) { $0 + $1.x }
            let sy = pts.reduce(0) { $0 + $1.y }
            return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
        }
        let eyeCenter = CGPoint(x: (center(left).x + center(right).x) / 2,
                                 y: (center(left).y + center(right).y) / 2)
        let nosePts: [CGPoint] = {
            if let nose = face.landmarks?.nose { return (0..<nose.pointCount).map { nose.normalizedPoints[$0] } }
            if let crest = face.landmarks?.noseCrest { return (0..<crest.pointCount).map { crest.normalizedPoints[$0] } }
            return []
        }()
        guard !nosePts.isEmpty else { return (0, "fallback-eyes") }
        let noseCenter = CGPoint(x: nosePts.map { $0.x }.reduce(0,+) / CGFloat(nosePts.count),
                                  y: nosePts.map { $0.y }.reduce(0,+) / CGFloat(nosePts.count))
        // Positive when nose below eyes in face coord space; scale by inter-ocular distance
        let dx = center(left).x - center(right).x
        let dy = center(left).y - center(right).y
        let interOcular = sqrt(dx*dx + dy*dy)
        let metric = Double((noseCenter.y - eyeCenter.y) / max(interOcular, 0.001))
        return (metric, "landmarks")
    }

    private func headLikelyFacingCamera(_ face: VNFaceObservation) -> Bool {
        if let yaw = face.yaw?.doubleValue, let roll = face.roll?.doubleValue {
            return abs(yaw) < 0.35 && abs(roll) < 0.35   // ~20°
        }
        return face.landmarks?.leftEye != nil && face.landmarks?.rightEye != nil
    }

    private func evaluateLooking(_ newValue: Bool) {
        let now = Date()
        if newValue != looking {
            let waited = now.timeIntervalSince(lastLookingFlip)
            let needed = newValue ? debounceOn : debounceOff
            if waited >= needed { setLooking(newValue) }
        } else {
            lastLookingFlip = now
        }
    }

    private func setLooking(_ value: Bool, force: Bool = false) {
        if value == looking && !force { return }
        looking = value
        lastLookingFlip = Date()
        onStateChanged?(value ? .looking : .away)
        if value {
            youtube.playIfYouTubeFrontmost()
        } else {
            youtube.pauseIfYouTubeFrontmost()
        }
    }

    private func startWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastFaceSeen) > 2.0 {
                self.evaluateLooking(false)
            }
        }
    }
}
