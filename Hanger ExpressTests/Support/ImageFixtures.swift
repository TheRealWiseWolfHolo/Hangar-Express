import Foundation
import UIKit

func makeSolidImageData(
    color: UIColor,
    size: CGSize = CGSize(width: 240, height: 240)
) -> Data {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true

    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }

    return image.jpegData(compressionQuality: 1) ?? Data()
}

func sampledColor(
    from image: UIImage,
    normalizedPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
) -> UIColor? {
    guard let cgImage = image.cgImage else {
        return nil
    }

    var pixel = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    let pixelX = CGFloat(min(max(Int(CGFloat(cgImage.width - 1) * normalizedPoint.x), 0), cgImage.width - 1))
    let pixelY = CGFloat(min(max(Int(CGFloat(cgImage.height - 1) * normalizedPoint.y), 0), cgImage.height - 1))

    context.translateBy(x: -pixelX, y: pixelY - CGFloat(cgImage.height) + 1)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

    return UIColor(
        red: CGFloat(pixel[0]) / 255,
        green: CGFloat(pixel[1]) / 255,
        blue: CGFloat(pixel[2]) / 255,
        alpha: CGFloat(pixel[3]) / 255
    )
}

func colorMatches(_ lhs: UIColor?, _ rhs: UIColor, tolerance: CGFloat = 0.12) -> Bool {
    guard let lhs,
          let lhsComponents = lhs.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components,
          let rhsComponents = rhs.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components,
          lhsComponents.count >= 3,
          rhsComponents.count >= 3 else {
        return false
    }

    return abs(lhsComponents[0] - rhsComponents[0]) <= tolerance
        && abs(lhsComponents[1] - rhsComponents[1]) <= tolerance
        && abs(lhsComponents[2] - rhsComponents[2]) <= tolerance
}

func colorsMatch(_ lhs: UIColor?, _ rhs: UIColor?, tolerance: CGFloat = 0.12) -> Bool {
    guard let rhs else {
        return lhs == nil
    }

    return colorMatches(lhs, rhs, tolerance: tolerance)
}
