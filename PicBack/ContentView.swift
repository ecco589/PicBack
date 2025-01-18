//
//  ContentView.swift
//  PicBack
//
//  Created by Ecco Liu on 2025/1/18.
//

import SwiftUI
import Photos

struct ContentView: View {
    @State private var selectedPhotos: Set<String> = []
    @State private var photoAssets: PHFetchResult<PHAsset>?
    @State private var showingPermissionAlert = false
    
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
                        NavigationLink(destination: MatchingView(selectedAssetIds: Array(selectedPhotos))) {
                            Text("开始匹配")
                        }
                    }
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
    
    private func checkPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    let fetchOptions = PHFetchOptions()
                    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    fetchOptions.includeHiddenAssets = true
                    fetchOptions.includeAllBurstAssets = true
                    photoAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
                case .denied, .restricted:
                    showingPermissionAlert = true
                default:
                    break
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
