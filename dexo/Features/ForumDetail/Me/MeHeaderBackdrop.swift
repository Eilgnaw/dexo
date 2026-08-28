import CoreImage
import Foundation
import UIKit

/// Navigation opacity follows scroll distance without changing content insets
/// or resizing the foreground UI.
struct MeHeaderScrollGeometry {
    let distance: CGFloat
    let pullDistance: CGFloat
    let navigationProgress: CGFloat

    init(contentOffsetY: CGFloat, topInset: CGFloat, avatarHeight: CGFloat) {
        distance = contentOffsetY + topInset
        pullDistance = max(0, -distance)
        let progress = min(1, max(0, distance / max(1, avatarHeight)))
        // Ease in: keep the first part subtle, reaching full opacity at the
        // same avatar-height distance without adding a visibility threshold.
        navigationProgress = progress * progress
    }

    static func backdropFrame(headerSize: CGSize, topInset: CGFloat, pullDistance: CGFloat) -> CGRect {
        CGRect(
            x: 0, y: -topInset - pullDistance,
            width: headerSize.width,
            height: headerSize.height + topInset + pullDistance + 28
        )
    }

    static func imageFrame(imageSize: CGSize, viewport: CGSize, pullDistance: CGFloat) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewport.width > 0 else { return .zero }
        let restingHeight = max(1, viewport.height - pullDistance)
        let coverScale = max(viewport.width / imageSize.width, restingHeight / imageSize.height)
        let stretch = 1 + pullDistance / restingHeight
        let size = CGSize(width: imageSize.width * coverScale * stretch, height: imageSize.height * coverScale * stretch)
        // Keep the photograph's top visible; a portrait image must stretch too.
        return CGRect(x: (viewport.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }
}

struct MeHeaderPreparedImage: @unchecked Sendable {
    let image: CGImage
    let tint: (red: CGFloat, green: CGFloat, blue: CGFloat)?

    nonisolated init(image: CGImage, tint: (CGFloat, CGFloat, CGFloat)?) {
        self.image = image
        self.tint = tint
    }
}

enum MeHeaderImageProcessor {
    /// Called on a background queue once per image, never during scrolling.
    nonisolated static func prepare(_ cgImage: CGImage, exifOrientation: Int32 = 1) -> MeHeaderPreparedImage? {
        let source = CIImage(cgImage: cgImage).oriented(forExifOrientation: exifOrientation)
        let longestEdge = max(source.extent.width, source.extent.height)
        guard longestEdge > 0, longestEdge.isFinite else { return nil }
        let scale = min(1, 1024 / longestEdge)
        let resized = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = resized.extent
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
        let bottomBand = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: max(1, extent.height * 0.3))
        let average = resized.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: bottomBand)])
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            context.render(average, toBitmap: address, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
        }
        let alpha = CGFloat(pixel[3]) / 255
        let tint: (CGFloat, CGFloat, CGFloat)? = alpha > 0.05 ? (
            min(1, CGFloat(pixel[0]) / 255 / alpha),
            min(1, CGFloat(pixel[1]) / 255 / alpha),
            min(1, CGFloat(pixel[2]) / 255 / alpha)
        ) : nil
        let blurred = resized.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
            .cropped(to: extent)
        guard let result = context.createCGImage(blurred, from: extent) else { return nil }
        return MeHeaderPreparedImage(image: result, tint: tint)
    }

    static func exifOrientation(for orientation: UIImage.Orientation) -> Int32 {
        switch orientation {
        case .up: return 1
        case .upMirrored: return 2
        case .down: return 3
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .right: return 6
        case .rightMirrored: return 7
        case .left: return 8
        @unknown default: return 1
        }
    }
}
