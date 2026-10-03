import AppKit
import AVFoundation
import CoreText
import Foundation
import ImageIO
import PDFKit

enum MediaMetadata {
    private static let imageExtensions = Set(["jpg", "jpeg", "png", "gif", "tiff", "tif", "heic", "heif", "webp", "avif", "bmp", "dng", "cr2", "cr3", "nef", "arw", "raw", "psd"])
    private static let audioExtensions = Set(["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf", "alac"])
    private static let videoExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpeg", "mpg", "mts", "m2ts", "3gp"])

    static func image(_ url: URL) -> [MetadataSection] {
        guard imageExtensions.contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [] }
        var fields = [(String, String)]()
        if let width = properties[kCGImagePropertyPixelWidth as String], let height = properties[kCGImagePropertyPixelHeight as String] { fields.append(("Dimensions", "\(width) × \(height) px")) }
        append(&fields, "Color model", properties[kCGImagePropertyColorModel as String])
        append(&fields, "Color profile", properties[kCGImagePropertyProfileName as String])
        append(&fields, "Bit depth", properties[kCGImagePropertyDepth as String])
        let frames = CGImageSourceGetCount(source)
        if frames > 1 { fields.append(("Images / frames", String(frames))) }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let camera = [tiff[kCGImagePropertyTIFFMake as String], tiff[kCGImagePropertyTIFFModel as String]].compactMap { $0 as? String }.joined(separator: " ")
        if !camera.isEmpty { fields.append(("Camera", camera)) }
        append(&fields, "Lens", exif[kCGImagePropertyExifLensModel as String])
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? NSNumber { fields.append(("Focal length", "\(focal) mm")) }
        if let aperture = exif[kCGImagePropertyExifFNumber as String] as? NSNumber { fields.append(("Aperture", "f/\(aperture)")) }
        if let seconds = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber {
            let value = seconds.doubleValue
            if value > 0 { fields.append(("Shutter", value < 1 ? String(format: "1/%.0f s", 1 / value) : "\(value) s")) }
        }
        append(&fields, "ISO", exif[kCGImagePropertyExifISOSpeedRatings as String])
        append(&fields, "Captured", exif[kCGImagePropertyExifDateTimeOriginal as String])
        append(&fields, "Author", tiff[kCGImagePropertyTIFFArtist as String])
        append(&fields, "Copyright", tiff[kCGImagePropertyTIFFCopyright as String])
        if let latitude = gps[kCGImagePropertyGPSLatitude as String] as? NSNumber,
           let longitude = gps[kCGImagePropertyGPSLongitude as String] as? NSNumber {
            let latSign = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -1.0 : 1.0
            let lonSign = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -1.0 : 1.0
            fields.append(("GPS", String(format: "%.6f, %.6f", latitude.doubleValue * latSign, longitude.doubleValue * lonSign)))
            append(&fields, "Altitude (m)", gps[kCGImagePropertyGPSAltitude as String])
        }
        // Report explicit metadata only; a wide-gamut profile alone does not establish HDR.
        let profile = (properties[kCGImagePropertyProfileName as String] as? String ?? "").lowercased()
        if profile.contains("hlg") { fields.append(("HDR transfer", "HLG (profile)")) }
        else if profile.contains("pq") || profile.contains("2084") { fields.append(("HDR transfer", "PQ (profile)")) }
        if let heics = properties["{HEICS}"] as? [String: Any], heics["HasHDRGainMap"] as? Bool == true || heics["HDRGainMapVersion"] != nil { fields.append(("HDR gain map", "Declared in image metadata")) }
        var sections = fields.isEmpty ? [] : [MetadataInspector.section("Image", fields)]
        if !iptc.isEmpty {
            let labels: [(String, String)] = [("ObjectName", "Title"), ("Byline", "Creator"), ("CopyrightNotice", "Copyright"), ("Keywords", "Keywords"), ("Caption/Abstract", "Caption"), ("City", "City"), ("Country/PrimaryLocationName", "Country")]
            var iptcFields = [(String, String)]()
            for (key, label) in labels { append(&iptcFields, label, iptc[key]) }
            if !iptcFields.isEmpty { sections.append(MetadataInspector.section("IPTC", iptcFields)) }
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            var xmp = [(String, String)]()
            for (path, label) in [("xmp:Rating", "Rating"), ("dc:creator", "Creator"), ("dc:rights", "Rights"), ("dc:subject", "Keywords"), ("xmp:CreatorTool", "Creator tool")] {
                if let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) { xmp.append((label, value as String)) }
            }
            if !xmp.isEmpty { sections.append(MetadataInspector.section("XMP", xmp)) }
        }
        return sections
    }

    static func pdf(_ url: URL) -> [MetadataSection] {
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else { return [] }
        var fields = [("Pages", String(document.pageCount)), ("Encryption", document.isEncrypted ? (document.isLocked ? "Password protected · locked" : "Encrypted · unlocked") : "Not encrypted")]
        if let attributes = document.documentAttributes {
            for (key, label) in [(PDFDocumentAttribute.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"), (.creatorAttribute, "Creator"), (.producerAttribute, "Producer")] {
                append(&fields, label, attributes[key])
            }
        }
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            fields.append(("First page", String(format: "%.0f × %.0f pt", box.width, box.height)))
        }
        return [MetadataInspector.section("PDF", fields)]
    }

    static func audioVideo(_ url: URL) async -> [MetadataSection] {
        let ext = url.pathExtension.lowercased()
        guard audioExtensions.contains(ext) || videoExtensions.contains(ext), !Task.isCancelled else { return [] }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { asset.cancelLoading() }
        }
        defer { watchdog.cancel(); asset.cancelLoading() }
        return await withTaskCancellationHandler(operation: {
            var fields = [(String, String)]()
            if let time = try? await asset.load(.duration) {
                let seconds = time.seconds
                if seconds.isFinite && seconds >= 0 { fields.append(("Duration", duration(seconds))) }
            }
            guard !Task.isCancelled, let tracks = try? await asset.load(.tracks) else {
                return fields.isEmpty ? [] : [MetadataInspector.section("Media", fields)]
            }
            let audio = tracks.filter { $0.mediaType == .audio }
            let video = tracks.filter { $0.mediaType == .video }
            fields.append(("Audio tracks", String(audio.count)))
            fields.append(("Subtitle tracks", String(tracks.filter { $0.mediaType == .subtitle || $0.mediaType == .text || $0.mediaType == .closedCaption }.count)))
            for track in video.prefix(1) {
                if let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                    let displayed = size.applying(transform)
                    fields.append(("Resolution", String(format: "%.0f × %.0f px", abs(displayed.width), abs(displayed.height))))
                }
                if let rate = try? await track.load(.nominalFrameRate), rate > 0 { fields.append(("Frame rate", String(format: "%.2f fps", rate))) }
                if let bitrate = try? await track.load(.estimatedDataRate), bitrate > 0 { fields.append(("Video bitrate", bitrateString(bitrate))) }
                if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
                    fields.append(("Video codec", fourCC(CMFormatDescriptionGetMediaSubType(format))))
                    let extensions = CMFormatDescriptionGetExtensions(format) as NSDictionary
                    if let transfer = extensions["TransferFunction"] as? String {
                        if transfer.contains("2084") { fields.append(("HDR transfer", "PQ / SMPTE ST 2084")) }
                        else if transfer.localizedCaseInsensitiveContains("HLG") || transfer.contains("2100") { fields.append(("HDR transfer", "HLG")) }
                    }
                    if let atoms = extensions["SampleDescriptionExtensionAtoms"] as? [String: Any], atoms["dvcC"] != nil || atoms["dvvC"] != nil { fields.append(("HDR format", "Dolby Vision configuration")) }
                }
            }
            for track in audio.prefix(1) {
                if let bitrate = try? await track.load(.estimatedDataRate), bitrate > 0 { fields.append(("Audio bitrate", bitrateString(bitrate))) }
                if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
                    fields.append(("Audio codec", fourCC(CMFormatDescriptionGetMediaSubType(format))))
                    if let audioDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                        fields.append(("Sample rate", String(format: "%.0f Hz", audioDescription.mSampleRate)))
                        fields.append(("Channels", String(audioDescription.mChannelsPerFrame)))
                    }
                }
            }
            if !Task.isCancelled, let common = try? await asset.load(.commonMetadata) {
                for item in common.prefix(60) {
                    guard let key = item.commonKey?.rawValue, let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                    if ["title", "artist", "albumName", "type", "description", "copyright", "creationDate"].contains(key) { fields.append((key == "albumName" ? "Album" : key.capitalized, value)) }
                }
            }
            if !Task.isCancelled, let locales = try? await asset.load(.availableChapterLocales), !locales.isEmpty {
                fields.append(("Chapters", String(asset.chapterMetadataGroups(withTitleLocale: locales[0], containingItemsWithCommonKeys: nil).count)))
            }
            return [MetadataInspector.section(video.isEmpty ? "Audio" : "Video", fields)]
        }, onCancel: { asset.cancelLoading() })
    }

    /// Embedded album art is a local fallback when Quick Look has no thumbnail.
    static func audioArtwork(_ url: URL) async -> NSImage? {
        guard audioExtensions.contains(url.pathExtension.lowercased()), !Task.isCancelled else { return nil }
        let asset = AVURLAsset(url: url)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { asset.cancelLoading() }
        }
        defer { watchdog.cancel(); asset.cancelLoading() }
        return await withTaskCancellationHandler(operation: {
            guard let items = try? await asset.load(.commonMetadata) else { return nil }
            for item in items.prefix(60) where item.commonKey == .commonKeyArtwork {
                guard !Task.isCancelled, let data = try? await item.load(.dataValue), data.count <= 2_097_152,
                      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary) else { continue }
                return NSImage(cgImage: image, size: .zero)
            }
            return nil
        }, onCancel: { asset.cancelLoading() })
    }

    static func design(_ url: URL) -> [MetadataSection] {
        let ext = url.pathExtension.lowercased()
        if ["ttf", "otf", "ttc", "dfont", "woff", "woff2"].contains(ext),
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let descriptor = descriptors.first {
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            return [MetadataInspector.section("Font", [("Family", CTFontCopyFamilyName(font) as String),
                ("Style", CTFontCopyFullName(font) as String), ("Glyphs", String(CTFontGetGlyphCount(font))), ("Faces", String(descriptors.count))])]
        }
        if ext == "svg", let data = MetadataInspector.boundedData(url), let text = String(data: data, encoding: .utf8) {
            guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else {
                return [MetadataInspector.section("SVG", [("XML", "Not validated; DTD parsing is disabled during hover inspection.")])]
            }
            let parser = XMLParser(data: data), counter = BoundedXMLCounter()
            parser.delegate = counter
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            let valid = parser.parse()
            var fields = [("XML", valid ? "Valid" : "Invalid or bounded preview"), ("Elements inspected", String(counter.elements))]
            for attribute in ["viewBox", "width", "height"] {
                if let regex = try? NSRegularExpression(pattern: "\\b\(attribute)\\s*=\\s*[\"']([^\"']+)[\"']"), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) { fields.append((attribute, String(text[range]))) }
            }
            return [MetadataInspector.section("SVG", fields)]
        }
        if ext == "psd", let data = MetadataInspector.boundedData(url, limit: 26), data.count >= 26, String(data: data.prefix(4), encoding: .ascii) == "8BPS" {
            func number(_ offset: Int, _ count: Int) -> UInt32 { data[offset..<(offset + count)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
            let modes = [0:"Bitmap", 1:"Grayscale", 2:"Indexed", 3:"RGB", 4:"CMYK", 7:"Multichannel", 8:"Duotone", 9:"Lab"]
            return [MetadataInspector.section("PSD", [("Dimensions", "\(number(18, 4)) × \(number(14, 4)) px"),
                ("Channels", String(number(12, 2))), ("Bit depth", String(number(22, 2))), ("Color mode", modes[Int(number(24, 2))] ?? "Unknown"),
                ("Layers", "Not inspected; native thumbnail may be available.")])]
        }
        if ["obj", "gltf", "glb", "usdz", "usd", "usda", "usdc", "stl", "fbx"].contains(ext) {
            if ext == "obj", let data = MetadataInspector.boundedData(url), let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return [MetadataInspector.section("3D model", [("Vertices inspected", String(lines.filter { $0.hasPrefix("v ") }.count)),
                    ("Faces inspected", String(lines.filter { $0.hasPrefix("f ") }.count)), ("Materials referenced", String(Set(lines.filter { $0.hasPrefix("usemtl ") }).count)),
                    ("Inspection", size > data.count ? "First 256 KB only" : "Complete OBJ text")])]
            }
            return [MetadataInspector.section("3D model", [("Format", ext.uppercased()), ("Deep structure", "Not inspected; native Quick Look is used when supported.")])]
        }
        return []
    }

    private static func append(_ fields: inout [(String, String)], _ label: String, _ value: Any?) {
        guard let value else { return }
        if let array = value as? [Any] { fields.append((label, array.prefix(30).map { String(describing: $0) }.joined(separator: ", "))) }
        else if let string = value as? String, !string.isEmpty { fields.append((label, string)) }
        else if let number = value as? NSNumber { fields.append((label, number.stringValue)) }
    }
    private static func duration(_ seconds: Double) -> String {
        let total = Int(min(seconds, Double(Int.max / 2)))
        return total >= 3_600 ? String(format: "%d:%02d:%02d", total / 3_600, total % 3_600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
    private static func bitrateString(_ bits: Float) -> String { String(format: "%.0f kb/s", bits / 1_000) }
    private static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
    }
}
