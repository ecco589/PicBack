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
    @State private var cachedFeatures: [String: ImageFeatures] = [:]
    @State private var isShowingProgress = false
    @State private var progress = 0
    
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
                            isShowingProgress = true
                            progress = 0
                            analyzeImages()
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
            .overlay {
                if isShowingProgress {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView("正在分析第 \(progress) 张，共 \(selectedPhotos.count) 张")
                            .tint(.white)
                            .foregroundColor(.white)
                    }
                    .frame(width: 200, height: 100)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                }
            }
        }
    }
    
    private func analyzeImages() {
        let totalCount = selectedPhotos.count
        progress = 0
        matchGroups = []  // 清空之前的结果
        
        // 在后台线程执行分析
        DispatchQueue.global(qos: .userInitiated).async {
            // 确保先构建特征缓存
            if cachedFeatures.isEmpty {
                buildFeatureCache()
            }
            
            var tempGroups: [MatchGroup] = []
            
            for (index, sourceId) in selectedPhotos.enumerated() {
                // 更新进度
                DispatchQueue.main.async {
                    progress = index + 1
                }
                
                guard let sourceAsset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceId], options: nil).firstObject,
                      let sourceFeatures = cachedFeatures[sourceId] else { continue }
                
                var matches: [MatchResult] = []
                for (targetId, targetFeatures) in cachedFeatures {
                    if targetId != sourceId {
                        let similarity = compareFeatures(source: sourceFeatures, target: targetFeatures)
                        if similarity >= 0.98 {
                            if let targetAsset = PHAsset.fetchAssets(withLocalIdentifiers: [targetId], options: nil).firstObject {
                                let result = MatchResult(
                                    sourceAsset: sourceAsset,
                                    matchedAsset: targetAsset,
                                    similarity: similarity,
                                    matchReason: getMatchReason(similarity: similarity)
                                )
                                matches.append(result)
                            }
                        }
                    }
                }
                
                matches.sort { $0.similarity > $1.similarity }
                let topMatches = Array(matches.prefix(3))
                let matchGroup = MatchGroup(sourceAsset: sourceAsset, matches: topMatches)
                tempGroups.append(matchGroup)
                
                // 完成后更新UI
                DispatchQueue.main.async {
                    if index == totalCount - 1 {
                        matchGroups = tempGroups
                        isShowingProgress = false
                        showingResults = true
                    }
                }
            }
        }
    }
    
    private func buildFeatureCache() {
        guard let assets = photoAssets else { return }
        
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isSynchronous = true
        
        assets.enumerateObjects { (asset, _, _) in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 100, height: 100),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                if let image = image {
                    let features = extractImageFeatures(from: image)
                    cachedFeatures[asset.localIdentifier] = features
                }
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
        return "完全匹配"  // 因为现在只显示98%以上的，所以都显示为完全匹配
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
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var selectedMatches: Set<String> = []
    
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
                            MatchGroupView(
                                group: group,
                                selectedMatches: $selectedMatches
                            )
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle("匹配结果")
        .toolbar {
            if !matchGroups.flatMap({ $0.matches }).isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: saveAllMatches) {
                        HStack {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("保存所有原图")
                            }
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .alert("保存成功", isPresented: $showingSaveSuccess) {
            Button("确定", role: .cancel) { }
        }
        .alert("保存失败", isPresented: .init(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("确定", role: .cancel) { }
        } message: {
            if let error = saveError {
                Text(error)
            }
        }
    }
    
    private func saveAllMatches() {
        isSaving = true
        let selectedAssets = matchGroups.flatMap { group in
            group.matches.filter { selectedMatches.contains($0.matchedAsset.localIdentifier) }
        }.map { $0.matchedAsset }
        
        guard !selectedAssets.isEmpty else {
            saveError = "请先选择要保存的照片"
            isSaving = false
            return
        }
        
        // 先请求写入权限
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    isSaving = false
                    saveError = "没有保存照片的权限"
                }
                return
            }
            
            var savedCount = 0
            var failedCount = 0
            
            // 在后台队列中执行保存操作
            DispatchQueue.global(qos: .userInitiated).async {
                for asset in selectedAssets {
                    let options = PHImageRequestOptions()
                    options.deliveryMode = .highQualityFormat
                    options.isNetworkAccessAllowed = true
                    options.isSynchronous = true
                    options.version = .original
                    
                    // 请求原始图片数据
                    PHImageManager.default().requestImageDataAndOrientation(
                        for: asset,
                        options: options
                    ) { imageData, uti, orientation, info in
                        guard let data = imageData,
                              let image = UIImage(data: data) else {
                            failedCount += 1
                            return
                        }
                        
                        // 创建新的照片资源
                        PHPhotoLibrary.shared().performChanges {
                            PHAssetCreationRequest.creationRequestForAsset(from: image)
                        } completionHandler: { success, error in
                            if success {
                                savedCount += 1
                            } else {
                                failedCount += 1
                                print("保存失败: \(error?.localizedDescription ?? "未知错误")")
                            }
                        }
                    }
                }
                
                // 等待所有保存操作完成后更新UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    isSaving = false
                    if failedCount == 0 && savedCount > 0 {
                        showingSaveSuccess = true
                    } else {
                        saveError = "成功保存\(savedCount)张，失败\(failedCount)张"
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
    @Binding var selectedMatches: Set<String>
    @State private var showingSaveSuccess = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var selectedPreviewAsset: PHAsset?
    
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
                                    ZStack(alignment: .topLeading) {
                                        Button {
                                            selectedPreviewAsset = result.matchedAsset
                                        } label: {
                                            AssetThumbnailView(asset: result.matchedAsset)
                                                .frame(width: 120, height: 120)
                                                .cornerRadius(8)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(selectedMatches.contains(result.matchedAsset.localIdentifier) ? Color.blue : Color.clear, lineWidth: 3)
                                                )
                                        }
                                        
                                        // 选择按钮
                                        Button {
                                            toggleSelection(result.matchedAsset.localIdentifier)
                                        } label: {
                                            Image(systemName: selectedMatches.contains(result.matchedAsset.localIdentifier) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 24))
                                                .foregroundColor(selectedMatches.contains(result.matchedAsset.localIdentifier) ? .blue : .white)
                                                .background(
                                                    Circle()
                                                        .fill(Color.black.opacity(0.3))
                                                        .padding(2)
                                                )
                                        }
                                        .padding(8)
                                    }
                                    
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
        .sheet(item: $selectedPreviewAsset) { asset in
            NavigationView {
                ImagePreviewView(asset: asset)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                toggleSelection(asset.localIdentifier)
                            } label: {
                                Image(systemName: selectedMatches.contains(asset.localIdentifier) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
            }
        }
    }
    
    private func toggleSelection(_ id: String) {
        if selectedMatches.contains(id) {
            selectedMatches.remove(id)
        } else {
            selectedMatches.insert(id)
        }
    }
    
    private func saveGroupMatches(_ matchGroup: MatchGroup) {
        isSaving = true
        
        // 先请求写入权限
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    isSaving = false
                    saveError = "没有保存照片的权限"
                }
                return
            }
            
            var savedCount = 0
            var failedCount = 0
            
            // 在后台队列中执行保存操作
            DispatchQueue.global(qos: .userInitiated).async {
                for asset in matchGroup.matches.map({ $0.matchedAsset }) {
                    let options = PHImageRequestOptions()
                    options.deliveryMode = .highQualityFormat
                    options.isNetworkAccessAllowed = true
                    options.isSynchronous = true
                    options.version = .original
                    
                    // 请求原始图片数据
                    PHImageManager.default().requestImageDataAndOrientation(
                        for: asset,
                        options: options
                    ) { imageData, uti, orientation, info in
                        guard let data = imageData,
                              let image = UIImage(data: data) else {
                            failedCount += 1
                            return
                        }
                        
                        // 创建新的照片资源
                        PHPhotoLibrary.shared().performChanges {
                            PHAssetCreationRequest.creationRequestForAsset(from: image)
                        } completionHandler: { success, error in
                            if success {
                                savedCount += 1
                            } else {
                                failedCount += 1
                                print("保存失败: \(error?.localizedDescription ?? "未知错误")")
                            }
                        }
                    }
                }
                
                // 等待所有保存操作完成后更新UI
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    isSaving = false
                    if failedCount == 0 && savedCount > 0 {
                        showingSaveSuccess = true
                    } else {
                        saveError = "成功保存\(savedCount)张，失败\(failedCount)张"
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

// 新增 PHAsset 的 Identifiable 扩展
extension PHAsset: Identifiable {
    public var id: String {
        return localIdentifier
    }
}

// 新增预览视图
struct ImagePreviewView: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        GeometryReader { geometry in
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            loadFullResolutionImage()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }
    
    private func loadFullResolutionImage() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
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
