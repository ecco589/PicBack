import SwiftUI
import Vision
import CoreML
import Photos

struct SmartMatchView: View {
    let sourceAssetIds: [String]
    @State private var matchResults: [MatchResult] = []
    @State private var isAnalyzing = false
    
    var body: some View {
        Group {
            if isAnalyzing {
                ProgressView("正在分析图片...")
            } else {
                List(matchResults) { result in
                    MatchResultRow(result: result)
                }
            }
        }
        .navigationTitle("匹配结果")
        .onAppear {
            analyzeImages()
        }
    }
    
    private func analyzeImages() {
        isAnalyzing = true
        
        // 获取所有照片
        let fetchOptions = PHFetchOptions()
        let allPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        
        // 创建分析请求
        guard let sourceAsset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceAssetIds.first!], options: nil).firstObject else {
            isAnalyzing = false
            return
        }
        
        ImageAnalyzer.analyze(sourceAsset: sourceAsset, allPhotos: allPhotos) { results in
            DispatchQueue.main.async {
                self.matchResults = results
                self.isAnalyzing = false
            }
        }
    }
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