import SwiftUI
import Photos

struct PhotoGridView: View {
    let assets: PHFetchResult<PHAsset>
    @Binding var selectedPhotos: Set<String>
    
    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<assets.count, id: \.self) { index in
                    let asset = assets[index]
                    PhotoThumbnailView(
                        asset: asset,
                        isSelected: selectedPhotos.contains(asset.localIdentifier)
                    )
                    .onTapGesture {
                        toggleSelection(asset)
                    }
                }
            }
            .padding(2)
        }
    }
    
    private func toggleSelection(_ asset: PHAsset) {
        if selectedPhotos.contains(asset.localIdentifier) {
            selectedPhotos.remove(asset.localIdentifier)
        } else {
            selectedPhotos.insert(asset.localIdentifier)
        }
    }
} 