import Vision
import Photos
import CoreImage

public class ImageMatchingService {
    static let shared = ImageMatchingService()
    private init() {}
    
    func findOriginalImage(for targetAsset: PHAsset, completion: @escaping (PHAsset?) -> Void) {
        // 获取所有照片资产，按创建时间排序
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        
        // 获取目标图像的特征和信息
        getImageData(for: targetAsset) { targetData in
            guard let targetData = targetData else {
                completion(nil)
                return
            }
            
            var bestMatch: (asset: PHAsset, score: Float)?
            let group = DispatchGroup()
            
            // 遍历所有照片寻找匹配
            for i in 0..<allAssets.count {
                let asset = allAssets[i]
                if asset.localIdentifier == targetAsset.localIdentifier {
                    continue
                }
                
                // 跳过分辨率更低的图片
                if asset.pixelWidth < targetData.width * 0.9 || 
                   asset.pixelHeight < targetData.height * 0.9 {
                    continue
                }
                
                group.enter()
                self.getImageData(for: asset) { assetData in
                    defer { group.leave() }
                    guard let assetData = assetData else { return }
                    
                    // 计算综合匹配分数
                    let score = self.calculateMatchScore(
                        target: targetData,
                        candidate: assetData
                    )
                    
                    if score > 0.85 { // 降低阈值以匹配水印图
                        if bestMatch == nil || score > bestMatch!.score {
                            bestMatch = (asset, score)
                        }
                    }
                }
            }
            
            group.notify(queue: .main) {
                completion(bestMatch?.asset)
            }
        }
    }
    
    private struct ImageData {
        let features: [Float]
        let histogram: [Float]
        let width: Int
        let height: Int
        let averageColor: CIColor
    }
    
    private func getImageData(for asset: PHAsset, completion: @escaping (ImageData?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.resizeMode = .none // 使用原始尺寸
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            guard let image = image,
                  let cgImage = image.cgImage else {
                completion(nil)
                return
            }
            
            // 1. 提取特征向量
            let requestHandler = VNImageRequestHandler(cgImage: cgImage)
            let featureRequest = VNFeaturePrintObservationRequest()
            
            // 2. 计算颜色直方图
            let histogramRequest = VNGenerateImageFeaturePrintRequest()
            
            do {
                try requestHandler.perform([featureRequest, histogramRequest])
                
                guard let featureObservation = featureRequest.results?.first as? VNFeaturePrintObservation,
                      let histogramObservation = histogramRequest.results?.first as? VNFeaturePrintObservation else {
                    completion(nil)
                    return
                }
                
                var features: [Float] = Array(repeating: 0, count: 512)
                var histogram: [Float] = Array(repeating: 0, count: 256)
                
                try featureObservation.copy(to: &features)
                try histogramObservation.copy(to: &histogram)
                
                // 3. 计算平均颜色
                let context = CIContext()
                let ciImage = CIImage(cgImage: cgImage)
                let extent = ciImage.extent
                let averageFilter = CIFilter(name: "CIAreaAverage",
                                          parameters: [kCIInputImageKey: ciImage,
                                                     kCIInputExtentKey: extent])!
                let outputImage = averageFilter.outputImage!
                let outputExtent = outputImage.extent
                let outputPixels = context.render(outputImage,
                                                toBitmap: nil,
                                                rowBytes: 4,
                                                bounds: outputExtent,
                                                format: .RGBA8,
                                                colorSpace: CGColorSpaceCreateDeviceRGB())
                let averageColor = CIColor(color: UIColor(red: CGFloat(outputPixels[0]),
                                                        green: CGFloat(outputPixels[1]),
                                                        blue: CGFloat(outputPixels[2]),
                                                        alpha: CGFloat(outputPixels[3])))
                
                let imageData = ImageData(
                    features: features,
                    histogram: histogram,
                    width: cgImage.width,
                    height: cgImage.height,
                    averageColor: averageColor
                )
                
                completion(imageData)
            } catch {
                completion(nil)
            }
        }
    }
    
    private func calculateMatchScore(target: ImageData, candidate: ImageData) -> Float {
        // 1. 特征向量相似度 (40%)
        let featureSimilarity = calculateCosineSimilarity(target.features, candidate.features)
        
        // 2. 颜色直方图相似度 (30%)
        let histogramSimilarity = calculateCosineSimilarity(target.histogram, candidate.histogram)
        
        // 3. 分辨率比较 (15%)
        let resolutionScore = min(
            Float(candidate.width) / Float(target.width),
            Float(candidate.height) / Float(target.height)
        )
        
        // 4. 颜色差异 (15%)
        let colorDifference = calculateColorDifference(target.averageColor, candidate.averageColor)
        let colorScore = 1 - min(colorDifference / 0.5, 1.0) // 归一化到 0-1
        
        // 综合评分
        return featureSimilarity * 0.4 +
               histogramSimilarity * 0.3 +
               Float(resolutionScore) * 0.15 +
               Float(colorScore) * 0.15
    }
    
    private func calculateCosineSimilarity(_ v1: [Float], _ v2: [Float]) -> Float {
        guard v1.count == v2.count else { return 0 }
        
        var dotProduct: Float = 0
        var norm1: Float = 0
        var norm2: Float = 0
        
        for i in 0..<v1.count {
            dotProduct += v1[i] * v2[i]
            norm1 += v1[i] * v1[i]
            norm2 += v2[i] * v2[i]
        }
        
        norm1 = sqrt(norm1)
        norm2 = sqrt(norm2)
        
        return dotProduct / (norm1 * norm2)
    }
    
    private func calculateColorDifference(_ c1: CIColor, _ c2: CIColor) -> CGFloat {
        let rDiff = pow(c1.red - c2.red, 2)
        let gDiff = pow(c1.green - c2.green, 2)
        let bDiff = pow(c1.blue - c2.blue, 2)
        return sqrt(rDiff + gDiff + bDiff)
    }
} 