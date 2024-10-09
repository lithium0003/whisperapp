//
//  Player.swift
//  transcribe
//
//  Created by rei9 on 2024/10/09.
//

import Foundation
import AVFoundation

class Player: NSObject {
    private(set) var recording = false
    private(set) var isLive = false
    private var outputBuf = [Float]()

    enum RecorderError: Error {
        case couldNotStartRecording
    }

    func startRecording(file: URL, callback: @escaping ([Float])-> Void) {
        if recording { return }
        recording = true
        Task.detached { [weak self] in
            defer {
                callback([])
                self?.isLive = false
                self?.recording = false
            }
            let accessing = file.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    file.stopAccessingSecurityScopedResource()
                }
            }
            let asset = AVURLAsset(url: file)
            guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 16000,
            ])
            reader.add(trackOutput)
            reader.startReading()
            self?.isLive = true

            while reader.status == .reading, self?.isLive == true {
                if let buffer = trackOutput.copyNextSampleBuffer() {
                    guard let dataBuffer = buffer.dataBuffer else {
                        debugPrint("No data buffer")
                        continue
                    }

                    let data = try dataBuffer.dataBytes()
                    self?.outputBuf.append(contentsOf: data.withUnsafeBytes {
                        Array($0.bindMemory(to: Float.self))
                    })
                }
                guard let self else { return }
                while outputBuf.count > 160 * 20 {
                    callback(Array(outputBuf[0..<(160 * 20)]))
                    outputBuf.removeFirst(160 * 20)
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
    }

    func stopRecording() {
        guard recording else { return }
        isLive = false
        recording = false
    }
}
