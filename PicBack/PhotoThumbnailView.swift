import SwiftUI
import Photos

struct PhotoThumbnailView: View {
    let asset: PHAsset
    let isSelected: Bool
    @State private var image: UIImage?
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: UIScreen.main.bounds.width / 3 - 4,
                           height: UIScreen.main.bounds.width / 3 - 4)
                    .clipped()
            } else {
                ProgressView()
                    .frame(width: UIScreen.main.bounds.width / 3 - 4,
                           height: UIScreen.main.bounds.width / 3 - 4)
            }
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .background(Circle().fill(Color.white))
                    .padding(4)
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isSynchronous = false
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 300, height: 300),
            contentMode: .aspectFill,
            options: options
        ) { result, info in
            if let image = result {
                self.image = image
            }
        }
    }
} 