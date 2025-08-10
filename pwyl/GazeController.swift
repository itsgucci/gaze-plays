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
    private let qualityRequest = VNDetectFaceCaptureQualityRequest()

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
        qualityRequest.inputFaceObservations = [baseFace]
        do {
            try handler.perform([landmarksRequest, qualityRequest])
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

        // Capture quality in [0,1]; higher is better
        let quality: Float = qualityRequest.results?.first?.faceCaptureQuality ?? 0

        let earMetrics = computeEyeAspectRatio(face)
        let earAvg = (earMetrics.left + earMetrics.right) / 2.0
        let eyesOpen = earAvg > earOpenThreshold
        let facing = headLikelyFacingCamera(face)
        let (vertical, verticalSource) = computeVerticalMetric(face)
        let lookingDown = vertical > pitchDownThreshold

        let faceFacingDown = true && facing && lookingDown
        evaluateLooking(faceFacingDown)

        let yaw = face.yaw?.doubleValue
        let roll = face.roll?.doubleValue
        let hasLeft = face.landmarks?.leftEye != nil
        let hasRight = face.landmarks?.rightEye != nil
        let dbg = "face: true | facing: \(facing) | down: \(lookingDown) | eyesOpen: \(eyesOpen) | quality: \(String(format: "%.2f", quality)) | earL: \(String(format: "%.2f", earMetrics.left)) (n=\(earMetrics.leftCount)) | earR: \(String(format: "%.2f", earMetrics.right)) (n=\(earMetrics.rightCount)) | earAvg: \(String(format: "%.2f", earAvg)) | earThresh: \(String(format: "%.2f", earOpenThreshold)) | vert(\(verticalSource)): \(String(format: "%.2f", vertical)) thr \(String(format: "%.2f", pitchDownThreshold)) | yaw: \(String(format: "%.2f", yaw ?? .nan)) | roll: \(String(format: "%.2f", roll ?? .nan))\nface&&facing&&down: \(faceFacingDown)"
        onDebug?(dbg)
    }

    private func eyesLikelyOpen(_ face: VNFaceObservation) -> Bool {
        let earAvg = computeEyeAspectRatio(face).average
        return earAvg > earOpenThreshold                 // tweakable threshold
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

    private func computeEyeAspectRatio(_ face: VNFaceObservation) -> (left: Double, right: Double, average: Double, leftCount: Int, rightCount: Int) {
        guard let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye else {
            return (0, 0, 0, 0, 0)
        }
        func robustEAR(_ eye: VNFaceLandmarkRegion2D) -> (value: Double, count: Int) {
            let points = (0..<eye.pointCount).map { eye.normalizedPoints[$0] }
            let count = points.count
            guard count >= 3 else { return (0, count) }
            if count >= 8 {
                let distance: (CGPoint, CGPoint) -> CGFloat = { a, b in
                    let dx = a.x - b.x, dy = a.y - b.y
                    return sqrt(dx*dx + dy*dy)
                }
                let horizontal = distance(points[0], points[4])
                let v1 = distance(points[1], points[5])
                let v2 = distance(points[2], points[6])
                let v3 = distance(points[3], points[7])
                let vertical = (v1 + v2 + v3) / 3
                return (Double(vertical / max(horizontal, 0.001)), count)
            } else {
                // Fallback: use bounding box aspect ratio for the eye polygon
                var minX = CGFloat.greatestFiniteMagnitude
                var maxX = -CGFloat.greatestFiniteMagnitude
                var minY = CGFloat.greatestFiniteMagnitude
                var maxY = -CGFloat.greatestFiniteMagnitude
                for p in points {
                    if p.x < minX { minX = p.x }
                    if p.x > maxX { maxX = p.x }
                    if p.y < minY { minY = p.y }
                    if p.y > maxY { maxY = p.y }
                }
                let horizontal = maxX - minX
                let vertical = maxY - minY
                return (Double(vertical / max(horizontal, 0.001)), count)
            }
        }
        let l = robustEAR(left)
        let r = robustEAR(right)
        let avg = (l.value + r.value) / 2.0
        return (l.value, r.value, avg, l.count, r.count)
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
