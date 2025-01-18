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
    @State private var matchGroups: [MatchGroup] = []
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
                    ResultsView(matchGroups: matchGroups, isAnalyzing: isAnalyzing)
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
        isAnalyzing = true
        matchGroups = []
        
        let group = DispatchGroup()
        var tempGroups: [MatchGroup] = []
        
        // 为每张选中的照片创建匹配组
        for sourceId in selectedPhotos {
            group.enter()
            
            guard let sourceAsset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceId], options: nil).firstObject else {
                group.leave()
                continue
            }
            
            analyzeImage(sourceAsset: sourceAsset) { results in
                let matchGroup = MatchGroup(sourceAsset: sourceAsset, matches: results)
                tempGroups.append(matchGroup)
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            matchGroups = tempGroups
            isAnalyzing = false
            showingResults = true
        }
    }
    
    // 单张图片分析函数
    private func analyzeImage(sourceAsset: PHAsset, completion: @escaping ([MatchResult]) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = true
        
        PHImageManager.default().requestImage(
            for: sourceAsset,
            targetSize: CGSize(width: 500, height: 500),
            contentMode: .aspectFit,
            options: options
        ) { sourceImage, _ in
            guard let sourceImage = sourceImage else {
                completion([])
                return
            }
            
            let sourceFeatures = extractImageFeatures(from: sourceImage)
            let allPhotos = PHAsset.fetchAssets(with: .image, options: nil)
            var tempResults: [MatchResult] = []
            let innerGroup = DispatchGroup()
            
            allPhotos.enumerateObjects { (asset, _, _) in
                if asset.localIdentifier != sourceAsset.localIdentifier {
                    innerGroup.enter()
                    PHImageManager.default().requestImage(
                        for: asset,
                        targetSize: CGSize(width: 500, height: 500),
                        contentMode: .aspectFit,
                        options: options
                    ) { image, _ in
                        defer { innerGroup.leave() }
                        
                        if let image = image {
                            let targetFeatures = extractImageFeatures(from: image)
                            let similarity = compareFeatures(source: sourceFeatures, target: targetFeatures)
                            
                            if similarity > 0.95 {
                                let result = MatchResult(
                                    sourceAsset: sourceAsset,
                                    matchedAsset: asset,
                                    similarity: similarity,
                                    matchReason: getMatchReason(similarity: similarity)
                                )
                                tempResults.append(result)
                            }
                        }
                    }
                }
            }
            
            innerGroup.notify(queue: .main) {
                completion(tempResults.sorted { $0.similarity > $1.similarity })
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
        if similarity > 0.98 {
            return "完全匹配"
        } else if similarity > 0.95 {
            return "极其相似"
        } else {
            return "相似图片"
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
    let matchGroups: [MatchGroup]
    let isAnalyzing: Bool
    @State private var showingSaveSuccess = false
    
    var body: some View {
        Group {
            if isAnalyzing {
                ProgressView("正在分析图片...")
            } else if matchGroups.isEmpty {
                ContentUnavailableView(
                    "没有找到相似图片",
                    systemImage: "photo.on.rectangle.slash",
                    description: Text("尝试选择其他图片或调整匹配条件")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(matchGroups) { group in
                            MatchGroupView(group: group)
                        }
                        
                        if matchGroups.contains(where: { !$0.matches.isEmpty }) {
                            Button(action: saveAllMatches) {
                                HStack {
                                    Image(systemName: "square.and.arrow.down.fill")
                                    Text("保存所有原图")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle("匹配结果")
        .alert("保存成功", isPresented: $showingSaveSuccess) {
            Button("确定", role: .cancel) { }
        }
    }
    
    private func saveAllMatches() {
        let assets = matchGroups.flatMap { $0.matches.map { $0.matchedAsset } }
        
        // 为每个资源创建一个图片请求队列
        for asset in assets {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = true
            options.version = .original  // 请求原始版本
            
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { imageData, dataUTI, orientation, info in
                guard let data = imageData else { return }
                
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        if success {
                            showingSaveSuccess = true
                        } else if let error = error {
                            print("保存失败: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }
}

struct MatchResult: Identifiable {
    let id = UUID()
    let sourceAsset: PHAsset  // 添加源图片信息
    let matchedAsset: PHAsset
    let similarity: Double
    let matchReason: String
}

struct MatchGroup: Identifiable {
    let id = UUID()
    let sourceAsset: PHAsset
    var matches: [MatchResult]
}

struct MatchGroupView: View {
    let group: MatchGroup
    @State private var showingSaveSuccess = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("源图片:")
                    .font(.headline)
                AssetThumbnailView(asset: group.sourceAsset)
                    .frame(width: 60, height: 60)
                    .cornerRadius(6)
            }
            .padding(.horizontal)
            
            if group.matches.isEmpty {
                ContentUnavailableView(
                    "未找到相似图片",
                    systemImage: "photo.on.rectangle.slash",
                    description: Text("没有找到相似度达到95%的图片")
                )
                .frame(height: 150)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("匹配结果:")
                            .font(.headline)
                        Spacer()
                        Button(action: { saveGroupMatches(group) }) {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("保存此组原图")
                            }
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(group.matches) { result in
                                VStack {
                                    AssetThumbnailView(asset: result.matchedAsset)
                                        .frame(width: 120, height: 120)
                                        .cornerRadius(8)
                                    Text("\(Int(result.similarity * 100))%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
        .alert("保存成功", isPresented: $showingSaveSuccess) {
            Button("确定", role: .cancel) { }
        }
    }
    
    private func saveGroupMatches(_ group: MatchGroup) {
        for asset in group.matches.map({ $0.matchedAsset }) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = true
            options.version = .original
            
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { imageData, dataUTI, orientation, info in
                guard let data = imageData else { return }
                
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        if success {
                            showingSaveSuccess = true
                        } else if let error = error {
                            print("保存失败: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
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
