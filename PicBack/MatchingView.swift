import SwiftUI
import Photos
import Vision
import CoreImage

struct MatchingView: View {
    let selectedAssetIds: [String]
    @State private var selectedAssets: [PHAsset] = []
    @State private var matchedPairs: [(original: PHAsset, matched: PHAsset?)] = []
    @State private var processingAssets = Set<String>()
    
    private let matcher = ImageMatcher()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(selectedAssets, id: \.localIdentifier) { asset in
                    MatchPairView(
                        originalAsset: asset,
                        matchedAsset: matchedPairs.first(where: { $0.original.localIdentifier == asset.localIdentifier })?.matched,
                        isProcessing: processingAssets.contains(asset.localIdentifier)
                    )
                }
            }
            .padding()
        }
        .navigationTitle("匹配结果")
        .onAppear {
            loadSelectedAssets()
            startMatching()
        }
    }
    
    private func loadSelectedAssets() {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: selectedAssetIds, options: nil)
        selectedAssets = (0..<assets.count).map { assets[$0] }
        matchedPairs = selectedAssets.map { ($0, nil) }
    }
    
    private func startMatching() {
        for asset in selectedAssets {
            processingAssets.insert(asset.localIdentifier)
            matcher.findOriginalImage(for: asset) { matchedAsset in
                if let index = matchedPairs.firstIndex(where: { $0.original.localIdentifier == asset.localIdentifier }) {
                    matchedPairs[index].matched = matchedAsset
                }
                processingAssets.remove(asset.localIdentifier)
            }
        }
    }
}

private class ImageMatcher {
    func findOriginalImage(for targetAsset: PHAsset, completion: @escaping (PHAsset?) -> Void) {
        print("开始匹配图片，目标图片ID: \(targetAsset.localIdentifier)")
        requestImage(for: targetAsset) { targetImage in
            guard let targetImage = targetImage else {
                print("无法获取目标图片")
                completion(nil)
                return
            }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.includeHiddenAssets = true
            fetchOptions.includeAllBurstAssets = true
            let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            print("找到 \(allAssets.count) 张照片进行匹配")
            
            var bestMatch: (asset: PHAsset, similarity: Double)?
            let group = DispatchGroup()
            
            for i in 0..<allAssets.count {
                let asset = allAssets[i]
                
                if asset.localIdentifier == targetAsset.localIdentifier {
                    continue
                }
                
                let targetRatio = Double(targetAsset.pixelWidth) / Double(targetAsset.pixelHeight)
                let assetRatio = Double(asset.pixelWidth) / Double(asset.pixelHeight)
                if abs(targetRatio - assetRatio) > 0.2 { // 放宽宽高比限制
                    continue
                }
                
                group.enter()
                self.requestImage(for: asset) { candidateImage in
                    defer { group.leave() }
                    guard let candidateImage = candidateImage else {
                        print("无法获取候选图片")
                        return
                    }
                    
                    let similarity = self.compareImages(targetImage, candidateImage)
                    print("图片相似度: \(similarity)")
                    
                    if similarity > 0.45 { // 大幅降低阈值以匹配更多可能的结果
                        if bestMatch == nil || similarity > bestMatch!.similarity {
                            print("找到更好的匹配: \(similarity)")
                            bestMatch = (asset, similarity)
                        }
                    }
                }
            }
            
            group.notify(queue: .main) {
                print("匹配完成，结果: \(bestMatch != nil)")
                completion(bestMatch?.asset)
            }
        }
    }
    
    private func requestImage(for asset: PHAsset, completion: @escaping (CIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = true
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            guard let image = image else {
                completion(nil)
                return
            }
            print("获取到图片尺寸: \(image.size)")
            completion(CIImage(image: image))
        }
    }
    
    private func compareImages(_ image1: CIImage, _ image2: CIImage) -> Double {
        // 直接计算特征相似度
        let featureSimilarity = compareImageFeatures(image1, image2)
        print("特征相似度: \(featureSimilarity)")
        
        // 只使用特征相似度
        return featureSimilarity
    }
    
    private func compareImageFeatures(_ image1: CIImage, _ image2: CIImage) -> Double {
        do {
            let request = VNGenerateImageFeaturePrintRequest()
            request.usesCPUOnly = true
            request.imageCropAndScaleOption = .scaleFit
            
            let handler1 = VNImageRequestHandler(ciImage: image1)
            let handler2 = VNImageRequestHandler(ciImage: image2)
            
            try handler1.perform([request])
            guard let observation1 = request.results?.first as? VNFeaturePrintObservation else {
                print("无法获取第一张图片的特征")
                return 0
            }
            
            try handler2.perform([request])
            guard let observation2 = request.results?.first as? VNFeaturePrintObservation else {
                print("无法获取第二张图片的特征")
                return 0
            }
            
            var distance: Float = 0
            try observation1.computeDistance(&distance, to: observation2)
            
            // 调整相似度计算
            let similarity = Double(1 - min(distance, 1.0))
            print("原始相似度: \(similarity)")
            return similarity > 0.5 ? similarity : 0
        } catch {
            print("特征比较失败: \(error)")
            return 0
        }
    }
    
    private func compareImageStructure(_ image1: CIImage, _ image2: CIImage) -> Double {
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: image1)
        
        do {
            let handler = VNImageRequestHandler(ciImage: image2)
            try handler.perform([request])
            
            if let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
                let alignmentX = abs(observation.alignmentTransform.tx)
                let alignmentY = abs(observation.alignmentTransform.ty)
                return 1 - min(sqrt(alignmentX * alignmentX + alignmentY * alignmentY) / 100, 1)
            }
        } catch {
            print("Structure comparison failed: \(error)")
        }
        return 0
    }
    
    private func computeImageDifference(_ image1: CIImage, _ image2: CIImage) -> Double {
        let context = CIContext()
        
        // 计算差异
        let differenceFilter = CIFilter(name: "CIDifferenceBlendMode")!
        differenceFilter.setValue(image1, forKey: kCIInputImageKey)
        differenceFilter.setValue(image2, forKey: kCIInputBackgroundImageKey)
        
        guard let differenceOutput = differenceFilter.outputImage else { return 0 }
        
        // 计算平均亮度
        let averageFilter = CIFilter(name: "CIAreaAverage")!
        averageFilter.setValue(differenceOutput, forKey: kCIInputImageKey)
        averageFilter.setValue(CIVector(cgRect: differenceOutput.extent), forKey: kCIInputExtentKey)
        
        guard let averageOutput = averageFilter.outputImage,
              let averageData = context.createCGImage(averageOutput, from: averageOutput.extent) else { return 0 }
        
        let dataProvider = averageData.dataProvider
        let data = dataProvider?.data
        let bytes = CFDataGetBytePtr(data)
        
        // 计算相似度（0表示完全相同，1表示完全不同）
        let difference = 1 - Double(bytes?[0] ?? 0) / 255.0
        return difference
    }
}

struct MatchPairView: View {
    let originalAsset: PHAsset
    let matchedAsset: PHAsset?
    let isProcessing: Bool
    @State private var showingSaveSuccess = false
    
    var body: some View {
        VStack {
            HStack {
                PhotoThumbnailView(asset: originalAsset, isSelected: false)
                    .frame(width: 150, height: 150)
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.blue)
                
                if isProcessing {
                    ProgressView()
                        .frame(width: 150, height: 150)
                } else if let matched = matchedAsset {
                    PhotoThumbnailView(asset: matched, isSelected: false)
                        .frame(width: 150, height: 150)
                } else {
                    ContentUnavailableView("未找到匹配", systemImage: "photo.badge.xmark")
                        .frame(width: 150, height: 150)
                }
            }
            
            if let matchedAsset = matchedAsset {
                Button("保存原版照片") {
                    saveOriginalPhoto(matchedAsset)
                }
                .buttonStyle(.bordered)
            }
        }
        .alert("保存成功", isPresented: $showingSaveSuccess) {
            Button("确定", role: .cancel) { }
        }
    }
    
    private func saveOriginalPhoto(_ asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            guard let image = image else { return }
            
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            showingSaveSuccess = true
        }
    }
} 
