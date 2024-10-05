//
//  ModelSelecter.swift
//  whisperapp
//
//  Created by rei9 on 2024/04/23.
//

import SwiftUI
import AVFoundation

struct ModelSelecter: View {
    @EnvironmentObject var userData: StateHolder
    @AppStorage("model_size") var model_size = "tiny"
    @StateObject var downloader = Downloader()

    let memSize = Int(round(Double(ProcessInfo.processInfo.physicalMemory) / (1000.0 * 1000.0 * 1000.0)))
    
    let sizes = [
        "tiny": "47MB",
        "base": "93MB",
        "small": "326MB",
        "medium": "1.0GB",
        "large-v2": "2.1GB",
        "large-v3": "2.1GB",
        "large-v3-turbo": "1.4GB",
    ]
    
    let modelList = ["tiny","base","small","medium","large-v3","large-v3-turbo"]
    
    var body: some View {
        VStack {
            Spacer()
            Text("Select model")
            Spacer()
            Text("Device memory size: \(memSize)GB")
            List {
                Section {
                    ForEach(modelList.filter({ $0 != "large-v3" || memSize > 5 }), id: \.self) { size in
                        HStack {
                            Image(systemName: size == model_size ? "checkmark.circle.fill" : "circle")
                                .renderingMode(.original)
                            Text(size)
                            Spacer()
                            Text(sizes[size]!)
                            Image(systemName: downloader.isDownloaded(model_size: size) ? "checkmark.circle" : "square.and.arrow.down")
                                .renderingMode(.original)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model_size = size
                        }
                    }
                }
                Section {
                    Button(action: {
                        downloader.clearAll()
                        downloader.copy_internal()
                        let size = model_size
                        model_size = ""
                        model_size = size
                    }, label: {
                        Text("Clear downloaded models")
                    })
                }
            }
            Group {
                if downloader.isDownloading {
                    Section("Download in progress") {
                        Text(downloader.message)
                            .font(.subheadline.monospacedDigit())
                        ProgressView(value: downloader.progress)
                    }
                }
                if downloader.isDownloading {
                    Button(role: .cancel, action: {
                        downloader.cancel()
                    }, label: {
                        Text("Cancel")
                    })
                }
            }
            Button(action: {
                if downloader.isDownloaded(model_size: model_size) {
                    userData.presentedPage += [.main(model_size: model_size)]
                }
                else {
                    downloader.download(model_size: model_size) { success in
                        if success {
                            Task.detached { @MainActor in
                                userData.presentedPage += [.main(model_size: model_size)]
                            }
                        }
                    }
                }
            }, label: {
                Text("Start")
            })
            .disabled(downloader.isDownloading)
            Spacer(minLength: 100)
        }
        .onAppear {
            downloader.copy_internal()
            Task {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .notDetermined:
                    print("notDetermined")
                    if await !AVCaptureDevice.requestAccess(for: .audio) {
                        print("failed")
                        return
                    }
                case .restricted:
                    print("restricted")
                case .denied:
                    print("denied")
                case .authorized:
                    print("granted")
                @unknown default:
                    fatalError()
                }
            }
        }
    }
}

#Preview {
    ModelSelecter()
}
