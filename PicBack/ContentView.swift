//
//  ContentView.swift
//  PicBack
//
//  Created by Ecco Liu on 2025/1/18.
//

import SwiftUI
import Photos
import Vision

struct ContentView: View {
    @State private var selectedPhotos: Set<String> = []
    @State private var photoAssets: PHFetchResult<PHAsset>?
    @State private var showingPermissionAlert = false
    @State private var matchResults: [MatchResult] = []
    @State private var isAnalyzing = false
    @State private var showingResults = false
    
    var body: some View {
        NavigationView {
            VStack {
                if let assets = photoAssets {
                    PhotoGridView(
                        assets: assets,
                        selectedPhotos: $selectedPhotos
                    )
                } else {
                    ContentUnavailableView(
                        "需要相册访问权限",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("请在设置中允许访问相册")
                    )
                }
            }
            .navigationTitle("选择照片")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !selectedPhotos.isEmpty {
                        Button("智能匹配") {
                            analyzeImages()
                            showingResults = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showingResults) {
                NavigationView {
                    ResultsView(matchResults: matchResults, isAnalyzing: isAnalyzing)
                }
            }
            .onAppear {
                checkPhotoLibraryPermission()
            }
            .alert("需要相册访问权限", isPresented: $showingPermissionAlert) {
                Button("打开设置", role: .none) {
                    if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsUrl)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请在设置中允许访问相册以使用照片匹配功能")
            }
        }
    }
    
    private func analyzeImages() {
        guard let sourceId = selectedPhotos.first,
              let sourceAsset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceId], options: nil).firstObject else {
            return
        }
        
        isAnalyzing = true
        matchResults = []
        
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = true
        
        // 1. 获取源图片
        PHImageManager.default().requestImage(
            for: sourceAsset,
            targetSize: CGSize(width: 500, height: 500),
            contentMode: .aspectFit,
            options: options
        ) { sourceImage, _ in
            guard let sourceImage = sourceImage else {
                isAnalyzing = false
                return
            }
            
            // 2. 获取源图片的特征
            let sourceFeatures = extractImageFeatures(from: sourceImage)
            
            // 3. 获取所有照片
            let allPhotos = PHAsset.fetchAssets(with: .image, options: nil)
            var tempResults: [MatchResult] = []
            let group = DispatchGroup()
            
            // 4. 遍历比较
            allPhotos.enumerateObjects { (asset, _, _) in
                if asset.localIdentifier != sourceId {
                    group.enter()
                    PHImageManager.default().requestImage(
                        for: asset,
                        targetSize: CGSize(width: 500, height: 500),
                        contentMode: .aspectFit,
                        options: options
                    ) { image, _ in
                        defer { group.leave() }
                        
                        if let image = image {
                            let targetFeatures = extractImageFeatures(from: image)
                            let similarity = compareFeatures(source: sourceFeatures, target: targetFeatures)
                            
                            if similarity > 0.3 { // 降低阈值以显示更多结果
                                let result = MatchResult(
                                    asset: asset,
                                    similarity: similarity,
                                    matchReason: getMatchReason(similarity: similarity)
                                )
                                tempResults.append(result)
                            }
                        }
                    }
                }
            }
            
            // 5. 等待所有处理完成
            group.notify(queue: .main) {
                matchResults = tempResults.sorted { $0.similarity > $1.similarity }
                isAnalyzing = false
                showingResults = true
            }
        }
    }
    
    private func requestImage(for asset: PHAsset, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 500, height: 500),
            contentMode: .aspectFit,
            options: options,
            resultHandler: { image, _ in
                completion(image)
            }
        )
    }
    
    private func getMatchReason(similarity: Double) -> String {
        if similarity > 0.8 {
            return "非常相似的图片"
        } else if similarity > 0.65 {
            return "相似的场景和颜色"
        } else if similarity > 0.5 {
            return "部分特征相似"
        } else {
            return "轻微相似"
        }
    }
    
    private func checkPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    let fetchOptions = PHFetchOptions()
                    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    photoAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
                case .denied, .restricted:
                    showingPermissionAlert = true
                default:
                    break
                }
            }
        }
    }
    
    private struct ImageFeatures {
        let averageColor: (r: Double, g: Double, b: Double)
        let histogram: [Double]
        let aspectRatio: Double
    }
    
    private func extractImageFeatures(from image: UIImage) -> ImageFeatures {
        guard let cgImage = image.cgImage else { 
            return ImageFeatures(averageColor: (0,0,0), histogram: [], aspectRatio: 1) 
        }
        
        let width = cgImage.width
        let height = cgImage.height
        let aspectRatio = Double(width) / Double(height)
        
        // 1. 计算平均颜色和直方图
        guard let pixelData = cgImage.dataProvider?.data else {
            return ImageFeatures(averageColor: (0,0,0), histogram: [], aspectRatio: aspectRatio)
        }
        
        let length = CFDataGetLength(pixelData)
        var buffer = [UInt8](repeating: 0, count: length)
        CFDataGetBytes(pixelData, CFRange(location: 0, length: length), &buffer)
        
        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0
        var histogram = [Double](repeating: 0, count: 8)
        
        let totalPixels = width * height
        
        for i in stride(from: 0, to: min(totalPixels * 4, buffer.count), by: 4) {
            let r = Double(buffer[i]) / 255.0
            let g = Double(buffer[i + 1]) / 255.0
            let b = Double(buffer[i + 2]) / 255.0
            
            // 累加颜色值计算平均值
            totalR += r
            totalG += g
            totalB += b
            
            // 计算直方图
            let index = min(
                Int(r * 2) + Int(g * 2) * 2 + Int(b * 2) * 4,
                histogram.count - 1
            )
            histogram[index] += 1.0
        }
        
        // 计算平均颜色
        let averageColor = (
            r: totalR / Double(totalPixels),
            g: totalG / Double(totalPixels),
            b: totalB / Double(totalPixels)
        )
        
        // 归一化直方图
        let sum = histogram.reduce(0, +)
        if sum > 0 {
            histogram = histogram.map { $0 / sum }
        }
        
        return ImageFeatures(
            averageColor: averageColor,
            histogram: histogram,
            aspectRatio: aspectRatio
        )
    }
    
    private func compareFeatures(source: ImageFeatures, target: ImageFeatures) -> Double {
        // 1. 颜色相似度 (50%)
        let colorDiff = sqrt(
            pow(source.averageColor.r - target.averageColor.r, 2) +
            pow(source.averageColor.g - target.averageColor.g, 2) +
            pow(source.averageColor.b - target.averageColor.b, 2)
        )
        let colorSimilarity = 1.0 - min(colorDiff / sqrt(3.0), 1.0)
        
        // 2. 直方图相似度 (30%)
        var histogramSimilarity = 0.0
        if !source.histogram.isEmpty && source.histogram.count == target.histogram.count {
            var diff = 0.0
            for i in 0..<source.histogram.count {
                diff += abs(source.histogram[i] - target.histogram[i])
            }
            histogramSimilarity = 1.0 - (diff / 2.0) // 归一化差异
        }
        
        // 3. 宽高比相似度 (20%)
        let aspectRatioDiff = abs(source.aspectRatio - target.aspectRatio)
        let aspectRatioSimilarity = 1.0 - min(aspectRatioDiff / 2.0, 1.0)
        
        // 加权平均
        return colorSimilarity * 0.5 + histogramSimilarity * 0.3 + aspectRatioSimilarity * 0.2
    }
}

struct ResultsView: View {
    let matchResults: [MatchResult]
    let isAnalyzing: Bool
    
    var body: some View {
        Group {
            if isAnalyzing {
                ProgressView("正在分析图片...")
            } else if matchResults.isEmpty {
                ContentUnavailableView(
                    "没有找到相似图片",
                    systemImage: "photo.on.rectangle.slash",
                    description: Text("尝试选择其他图片或调整匹配条件")
                )
            } else {
                List(matchResults) { result in
                    MatchResultRow(result: result)
                }
            }
        }
        .navigationTitle("匹配结果")
    }
}

struct MatchResult: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let similarity: Double
    let matchReason: String
}

struct MatchResultRow: View {
    let result: MatchResult
    
    var body: some View {
        HStack {
            AssetThumbnailView(asset: result.asset)
                .frame(width: 80, height: 80)
                .cornerRadius(8)
            
            VStack(alignment: .leading) {
                Text("相似度: \(Int(result.similarity * 100))%")
                    .font(.headline)
                Text(result.matchReason)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AssetThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage?
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 200, height: 200),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let image = result {
                self.image = image
            }
        }
    }
}

#Preview {
    ContentView()
}
