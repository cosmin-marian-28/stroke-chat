import Flutter
import UIKit
import Vision
import CoreImage

class BgRemovalPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.strokechat/bg_removal",
            binaryMessenger: registrar.messenger()
        )
        let instance = BgRemovalHandler()
        channel.setMethodCallHandler(instance.handle)
    }
}

private class BgRemovalHandler {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "removeBackground":
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputPath = args["outputPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing paths", details: nil))
                return
            }
            let quality = args["quality"] as? String ?? "accurate"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.processFrame(inputPath: inputPath, outputPath: outputPath, quality: quality)
                    DispatchQueue.main.async { result(true) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                    }
                }
            }

        case "removeBgBatch":
            guard let args = call.arguments as? [String: Any],
                  let inputPaths = args["inputPaths"] as? [String],
                  let outputPaths = args["outputPaths"] as? [String] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing paths", details: nil))
                return
            }
            let quality = args["quality"] as? String ?? "accurate"
            DispatchQueue.global(qos: .userInitiated).async {
                let count = min(inputPaths.count, outputPaths.count)
                var success = 0
                let lock = NSLock()
                let group = DispatchGroup()
                let queue = DispatchQueue(label: "bg.batch", attributes: .concurrent)

                // Process 4 frames at a time
                for chunk in stride(from: 0, to: count, by: 4) {
                    let end = min(chunk + 4, count)
                    for i in chunk..<end {
                        group.enter()
                        queue.async {
                            do {
                                try self.processFrame(inputPath: inputPaths[i], outputPath: outputPaths[i], quality: quality)
                                lock.lock(); success += 1; lock.unlock()
                            } catch {
                                print("BgRemoval frame \(i): \(error.localizedDescription)")
                            }
                            group.leave()
                        }
                    }
                    group.wait()
                }
                DispatchQueue.main.async { result(success) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func processFrame(inputPath: String, outputPath: String, quality: String) throws {
        guard #available(iOS 15.0, *) else {
            throw NSError(domain: "BgRemoval", code: 0, userInfo: [NSLocalizedDescriptionKey: "iOS 15+"])
        }
        guard let uiImage = UIImage(contentsOfFile: inputPath),
              let cgImage = uiImage.cgImage else {
            throw NSError(domain: "BgRemoval", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't load"])
        }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality == "fast" ? .fast : .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let mask = request.results?.first else {
            throw NSError(domain: "BgRemoval", code: 2, userInfo: [NSLocalizedDescriptionKey: "No result"])
        }

        let ciImage = CIImage(cgImage: cgImage)
        var ciMask = CIImage(cvPixelBuffer: mask.pixelBuffer)

        // Feather edges — smooth the mask boundary
        let blur = max(ciImage.extent.width, ciImage.extent.height) * 0.01
        if let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: ciMask, kCIInputRadiusKey: blur
        ])?.outputImage {
            ciMask = blurred.clamped(to: ciMask.extent).cropped(to: ciMask.extent)
        }

        let sx = ciImage.extent.width / ciMask.extent.width
        let sy = ciImage.extent.height / ciMask.extent.height
        let scaled = ciMask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(ciImage, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(scaled, forKey: kCIInputMaskImageKey)

        guard let out = blend.outputImage,
              let cg = ciContext.createCGImage(out, from: ciImage.extent) else {
            throw NSError(domain: "BgRemoval", code: 3, userInfo: [NSLocalizedDescriptionKey: "Blend fail"])
        }

        guard let png = UIImage(cgImage: cg).pngData() else {
            throw NSError(domain: "BgRemoval", code: 4, userInfo: [NSLocalizedDescriptionKey: "PNG fail"])
        }
        try png.write(to: URL(fileURLWithPath: outputPath))
    }
}
