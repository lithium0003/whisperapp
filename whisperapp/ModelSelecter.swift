//
//  ModelSelecter.swift
//  whisperapp
//
//  Created by rei9 on 2024/04/23.
//

import SwiftUI
import AVFoundation

struct ModelSelecter: View {
    @StateObject var downloader = Downloader()
    @State private var isShowing = false
    @AppStorage("model_size") var model_size = "base"

    let sizes = [
        "tiny": "73MB",
        "base": "139MB",
        "small": "462MB",
        "medium": "1.5GB",
        "large-v3": "1.9GB",
    ]
    
    var body: some View {
        VStack {
            Spacer()
            Text("Select model")
            Spacer()
            List {
                Section {
                    ForEach(["tiny","base","small","medium","large-v3"], id: \.self) { size in
                        HStack {
                            Image(systemName: size == model_size ? "checkmark.circle.fill" : "circle")
                                .renderingMode(.original)
                            Text(size)
                            if size == "large-v3" {
                                Text("(q8_0, trim)")
                            }
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
                        let size = model_size
                        model_size = ""
                        model_size = size
                    }, label: {
                        Text("Clear downloaded models")
                    })
                }
                if downloader.isDownloading {
                    Section("Download in progress") {
                        Text(downloader.message)
                            .font(.subheadline.monospacedDigit())
                        ProgressView(value: downloader.progress)
                    }
                }
            }
            if downloader.isDownloading {
                Button(role: .cancel, action: {
                    downloader.cancel()
                }, label: {
                    Text("Cancel")
                })
            }
            Button(action: {
                if downloader.isDownloaded(model_size: model_size) {
                    isShowing.toggle()
                }
                else {
                    downloader.download(model_size: model_size) { success in
                        if success {
                            Task.detached { @MainActor in
                                isShowing.toggle()
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
            Task {
                switch AVAudioApplication.shared.recordPermission {
                case .undetermined:
                    print("undetermined")
                    if await !AVAudioApplication.requestRecordPermission() {
                        print("failed")
                        return
                    }
                case .denied:
                    print("denied")
                    return
                case .granted:
                    print("granted")
                    break
                @unknown default:
                    fatalError()
                }
            }
        }
        .fullScreenCover(isPresented: $isShowing) {
            ContentView(whisperState: WhisperState(model_size: model_size))
        }
    }
}

#Preview {
    ModelSelecter()
}
