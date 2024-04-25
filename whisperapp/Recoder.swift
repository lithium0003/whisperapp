//
//  Recoder.swift
//  whisperapp
//
//  Created by rei9 on 2024/04/17.
//

import Foundation
import AVFoundation
import UIKit

actor Recorder {
    private let audioEngine = AVAudioEngine()
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    func startRecording(callback: @escaping ([Float])-> Void) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        let inputNode = audioEngine.inputNode

        let recodingFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: true) else {
            print("Can't create output format")
            return
        }
        guard let converter: AVAudioConverter = AVAudioConverter(from: recodingFormat, to: outputFormat) else {
            print("Can't convert in to this format")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(recodingFormat.sampleRate), format: recodingFormat) { (buffer, time) in
            var newBufferAvailable = true

            let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if newBufferAvailable {
                    outStatus.pointee = .haveData
                    newBufferAvailable = false
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            guard let newbuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputFormat.sampleRate * 0.2)) else {
                return
            }

            while true {
                var error: NSError?
                let status = converter.convert(to: newbuffer, error: &error, withInputFrom: inputCallback)
                if let error = error {
                    print(error)
                }
                
                if status == .haveData {
                    let len = Int(newbuffer.frameLength)
                    guard let p = newbuffer.floatChannelData?[0] else { return }
                    let fdata = Array(UnsafeBufferPointer(start: p, count: len))
                    callback(fdata)
                }
                else {
                    break
                }
            }
        }
        Task.detached { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = true
        }
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    func stopRecording() {
        Task.detached { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = false
        }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}
