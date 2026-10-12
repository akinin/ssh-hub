import AppKit
import ImageIO

enum ConnectionLogo {
    static func load(_ url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 10_000_000 else {
            throw ConfigError.message("Изображение больше 10 МБ.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 10_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw ConfigError.message("Не удалось прочитать изображение. Выбери PNG, JPEG или WebP.") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]), ConnectionAppearance.validLogo(png) else {
            throw ConfigError.message("Не удалось подготовить логотип. Попробуй другое изображение.")
        }
        return png
    }
}

