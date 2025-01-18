import Vision
import Photos
import CoreImage

class ImageAnalyzer {
    static func analyze(sourceAsset: PHAsset, allPhotos: PHFetchResult<PHAsset>, completion: @escaping ([MatchResult]) -> Void) {
        // 获取源图片的特征
        getImageFeatures(for: sourceAsset) { sourceFeatures in
            guard let sourceFeatures = sourceFeatures else {
                completion([])
                return
            }
            
            var results: [MatchResult] = []
            let group = DispatchGroup()
            
            // 分析所有其他图片
            allPhotos.enumerateObjects { (asset, _, _) in
                if asset.localIdentifier != sourceAsset.localIdentifier {
                    group.enter()
                    getImageFeatures(for: asset) { features in
                        if let features = features {
                            let similarity = calculateSimilarity(source: sourceFeatures, target: features)
                            if similarity > 0.6 { // 只保留相似度超过60%的结果
                                let reason = determineMatchReason(similarity: similarity)
                                results.append(MatchResult(asset: asset, similarity: similarity, matchReason: reason))
                            }
                        }
                        group.leave()
                    }
                }
            }
            
            group.notify(queue: .main) {
                // 按相似度排序
                let sortedResults = results.sorted { $0.similarity > $1.similarity }
                completion(Array(sortedResults.prefix(10))) // 只返回最相似的10张
            }
        }
    }
    
    private static func getImageFeatures(for asset: PHAsset, completion: @escaping (ImageFeatures?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 500, height: 500),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            guard let image = image else {
                completion(nil)
                return
            }
            
            let features = ImageFeatures(
                dominantColors: extractDominantColors(from: image),
                composition: analyzeComposition(image),
                scene: detectScene(image)
            )
            completion(features)
        }
    }
}

struct ImageFeatures {
    let dominantColors: [UIColor]
    let composition: CompositionType
    let scene: SceneType
}

enum CompositionType {
    case centered
    case rule3rds
    case landscape
    case portrait
    case other
}

enum SceneType {
    case nature
    case urban
    case indoor
    case people
    case other
}

extension ImageAnalyzer {
    private static func extractDominantColors(from image: UIImage) -> [UIColor] {
        guard let cgImage = image.cgImage else { return [] }
        
        let width = 50
        let height = 50
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        
        var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var colors: [UIColor] = []
        var colorCounts: [String: Int] = [:]
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = CGFloat(rawData[offset]) / 255.0
                let g = CGFloat(rawData[offset + 1]) / 255.0
                let b = CGFloat(rawData[offset + 2]) / 255.0
                
                // 简化颜色以减少变化
                let simplifiedR = round(r * 4) / 4
                let simplifiedG = round(g * 4) / 4
                let simplifiedB = round(b * 4) / 4
                
                let colorKey = "\(simplifiedR),\(simplifiedG),\(simplifiedB)"
                colorCounts[colorKey, default: 0] += 1
            }
        }
        
        // 获取出现次数最多的颜色
        let sortedColors = colorCounts.sorted { $0.value > $1.value }
        for colorKey in sortedColors.prefix(3) {
            let components = colorKey.key.split(separator: ",").compactMap { CGFloat(Double($0)!) }
            colors.append(UIColor(red: components[0], green: components[1], blue: components[2], alpha: 1.0))
        }
        
        return colors
    }
    
    private static func analyzeComposition(_ image: UIImage) -> CompositionType {
        let ratio = image.size.width / image.size.height
        
        if ratio > 1.3 {
            return .landscape
        } else if ratio < 0.8 {
            return .portrait
        } else {
            return .centered
        }
    }
    
    private static func detectScene(_ image: UIImage) -> SceneType {
        // 简单的场景检测逻辑
        guard let cgImage = image.cgImage else { return .other }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage)
        let request = VNClassifyImageRequest()
        
        try? requestHandler.perform([request])
        
        guard let observations = request.results as? [VNClassificationObservation] else {
            return .other
        }
        
        // 根据分类结果判断场景类型
        for observation in observations {
            let identifier = observation.identifier.lowercased()
            if identifier.contains("nature") || identifier.contains("outdoor") {
                return .nature
            } else if identifier.contains("building") || identifier.contains("city") {
                return .urban
            } else if identifier.contains("indoor") || identifier.contains("room") {
                return .indoor
            } else if identifier.contains("person") || identifier.contains("face") {
                return .people
            }
        }
        
        return .other
    }
    
    private static func calculateSimilarity(source: ImageFeatures, target: ImageFeatures) -> Double {
        var similarity = 0.0
        
        // 颜色相似度 (40%)
        let colorSimilarity = calculateColorSimilarity(source.dominantColors, target.dominantColors)
        similarity += colorSimilarity * 0.4
        
        // 构图相似度 (30%)
        let compositionSimilarity = source.composition == target.composition ? 1.0 : 0.0
        similarity += compositionSimilarity * 0.3
        
        // 场景相似度 (30%)
        let sceneSimilarity = source.scene == target.scene ? 1.0 : 0.0
        similarity += sceneSimilarity * 0.3
        
        return similarity
    }
    
    private static func calculateColorSimilarity(_ colors1: [UIColor], _ colors2: [UIColor]) -> Double {
        guard !colors1.isEmpty && !colors2.isEmpty else { return 0.0 }
        
        var totalSimilarity = 0.0
        for color1 in colors1 {
            var maxSimilarity = 0.0
            for color2 in colors2 {
                let similarity = colorDistance(color1, color2)
                maxSimilarity = max(maxSimilarity, similarity)
            }
            totalSimilarity += maxSimilarity
        }
        
        return totalSimilarity / Double(colors1.count)
    }
    
    private static func colorDistance(_ color1: UIColor, _ color2: UIColor) -> Double {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        
        color1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        
        let rDiff = r1 - r2
        let gDiff = g1 - g2
        let bDiff = b1 - b2
        
        let distance = sqrt(rDiff * rDiff + gDiff * gDiff + bDiff * bDiff)
        return 1.0 - min(distance, 1.0)
    }
    
    private static func determineMatchReason(similarity: Double) -> String {
        if similarity > 0.9 {
            return "非常相似的图片"
        } else if similarity > 0.8 {
            return "相似的场景和颜色"
        } else if similarity > 0.7 {
            return "类似的构图风格"
        } else {
            return "部分特征相似"
        }
    }
} 