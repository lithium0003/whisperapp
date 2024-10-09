//
//  WhisperState.swift
//  whisper
//
//  Created by rei9 on 2024/04/17.
//

import Foundation
import AVFoundation
import Accelerate
import Combine
import SwiftUI

class WhisperState: NSObject, ObservableObject {
    let model_size: String
    @Published var isModelLoaded = false
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var isProcessing = false
    @Published var fixLanguage = "auto"
    @Published var transrate = false
    @Published var messageLog: [AttributedString] = []
    @Published var messageTiming: [Double] = []
    @Published var currentGain = 1.0
    @Published var timeCount = 0

    var active = false
    var waitTime = 0.0
    var internalWaitTime = 0.0
    var callCount: UInt64 = 0
    var language = ""
    var languageCutoff = 0.5
    var volLeveldB: Float = -40
    var volDev: Float = 0
    var silentLeveldB: Float = -0
    var volDevThreshold: Float = 0.9
    var gainTargetdB: Float = -5

    var logBuffer: [TimeKey: AttributedString] = [:]

    @Published var bufferSec = 30
    @Published var contCount = 5

    var silenceMap: [Double: Double] = [:]
    func fixTimestamp(_ t: Double) -> Double {
        var silence = 0.0
        for (key, value) in silenceMap.sorted(by: { $0.key < $1.key }) {
            if t + value < key {
                return t + silence
            }
            silence += value
        }
        return t + silence
    }
    
    
    var languageList: [String] {
        if let list = whisperContext?.languageList {
            return ["auto"] + list
        }
        return ["auto"]
    }

    private var whisperContext: WhisperContext?
    private var recorder = Recorder()
    private var player = Player()

    private var modelUrl: URL? {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let models = cache.appending(path: "models")
        let index = models.appending(path: "index").appending(path: "\(model_size)")
        guard let data = try? String(contentsOf: index, encoding: .utf8) else {
            return nil
        }
        guard let bin = data.components(separatedBy: .newlines).filter({ !$0.contains("mlmodelc") }).first(where: { $0.hasSuffix(".bin") }) else {
            return nil
        }
        return models.appending(path: bin)
    }

    private enum LoadError: Error {
        case couldNotLocateModel
    }

    init(model_size: String) {
        self.model_size = model_size
        super.init()
        loadModel()
    }

    deinit {
        whisperContext = nil
    }

    func purge() async {
        await whisperContext?.kill()
        whisperContext = nil
    }

    @MainActor
    func clearLog() {
        messageLog = []
        timeCount = 0
        logBuffer.removeAll()
        silenceMap.removeAll()
        Task {
            await whisperContext?.reset()
        }
    }

    private func loadModel() {
        Task.detached { @MainActor [self] in
            messageLog.append("Loading model...")
        }
        let model_size = model_size
        if let modelUrl {
            Task.detached {
                let outPipe = Pipe()
                let redirector = AsyncThrowingStream<String, Error> { continuation in
                    Task.detached {
                        outPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                            let data = fileHandle.availableData
                            if data.isEmpty  { // end-of-file condition
                                fileHandle.readabilityHandler = nil
                                continuation.finish()
                            } else {
                                continuation.yield(String(data: data,  encoding: .utf8)!)
                            }
                        }

                        // Redirect
                        setvbuf(stderr, nil, _IONBF, 0)
                        let savedStderr = dup(STDERR_FILENO)
                        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

                        do {
                            let context = try WhisperContext.createContext(path: modelUrl.path(), model: model_size)

                            Task.detached { @MainActor in
                                self.whisperContext = context
                            }
                        }
                        catch {
                            continuation.finish(throwing: error)
                        }
                        
                        // Undo redirection
                        dup2(savedStderr, STDERR_FILENO)
                        close(outPipe.fileHandleForWriting.fileDescriptor)
                        try! outPipe.fileHandleForWriting.close()
                        close(savedStderr)
                    }
                }

                do {
                    for try await log in redirector {
                        Task.detached { @MainActor [self] in
                            messageLog.append(contentsOf: log.split(whereSeparator: \.isNewline).map({ AttributedString($0) }))
                        }
                    }
                    Task.detached { @MainActor [self] in
                        messageLog.append(AttributedString("Loaded model \(modelUrl.lastPathComponent)"))
                        messageLog.append(contentsOf: ["", "Ready to run.", ""])
                    }
                    Task.detached { @MainActor in
                        self.isModelLoaded = true
                    }
                } catch {
                    Task.detached { @MainActor [self] in
                        messageLog.append("Error in loading model.")
                    }
                }
            }
        } else {
            Task.detached { @MainActor [self] in
                messageLog.append(contentsOf: ["Could not locate model"])
            }
        }
    }

    actor Processer {
        private(set) var gain: Float = 1.0
        private let contCount: Int
        private var scount: Int
        private var lastCall = Date()
        private var remainCall = Date()
        private var logBuffer: [TimeKey: AttributedString] = [:]

        func stop() async {
            await parent.whisperContext?.clear()
        }

        class SoundBuffer {
            private var soundBuf: [Float] = []
            private var preBuffer: [Float] = []
            private let preLength = 1600 * 2 * 2 // 400ms
            private var rIdx = 0
            private var wIdx = 0
            let callLength: Int
            private let contCount: Int
            private var processing_samples = 0
            var lastSound = Date()
            private var wavCache: [Float] = []
            private var rawSpecCache: [Float] = []
            private var voiceSpecCache: [Float] = []

            
            init(callLength: Int, contCount: Int) {
                self.callLength = callLength
                self.contCount = contCount
            }

            func done_processing(sample_count: Int) {
                processing_samples -= sample_count
                if processing_samples < 0 {
                    processing_samples = 0
                }
            }

            func get_waittime() -> Double {
                return Double(soundBuf.count + processing_samples) / 16000
            }

            func clear() {
                soundBuf.removeAll()
            }

            func append_preData(data: [Float]) {
                preBuffer.append(contentsOf: data)
                let rmLength = preBuffer.count - preLength
                if rmLength > 0 {
                    preBuffer.removeFirst(rmLength)
                }
            }

            func append_data(data: [Float]) {
                let fixData: [Float]
                if !preBuffer.isEmpty {
                    fixData = preBuffer + data
                }
                else {
                    fixData = data
                }
                preBuffer = []
                soundBuf.append(contentsOf: fixData)
            }

            func read_buffer(internalLength: Int) -> (buf: [Float], flush: Bool) {
                if soundBuf.count >= callLength {
                    let buf = soundBuf
                    soundBuf.removeAll()
                    processing_samples += buf.count
                    return (buf: buf, flush: false)
                }
                if soundBuf.count > 16000 * 5, soundBuf.count + internalLength > callLength {
                    let buf = soundBuf
                    soundBuf.removeAll()
                    processing_samples += buf.count
                    return (buf: buf, flush: false)
                }
                else if lastSound.timeIntervalSinceNow < -5 {
                    let buf = soundBuf
                    soundBuf.removeAll()
                    if !buf.isEmpty {
                        processing_samples += buf.count
                        return (buf: buf, flush: true)
                    }
                    return (buf: [], flush: false)
                }
                return (buf: [], flush: false)
            }

            func flush_buffer() -> [Float] {
                let buf = soundBuf
                soundBuf.removeAll()
                processing_samples += buf.count
                return buf
            }
        }
        private var buffer: SoundBuffer
        nonisolated private let parent: WhisperState

        init(parent: WhisperState) {
            self.parent = parent
            self.contCount = parent.contCount
            self.buffer = SoundBuffer(callLength: 16000 * parent.bufferSec, contCount: contCount)
            self.scount = contCount
            self.logBuffer = parent.logBuffer
        }

        let fft_n = 512
        lazy var fft = {
            let log2n = vDSP_Length(log2(Float(fft_n)) + 1)
            let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
            return fft
        }()
        lazy var window = {
            vDSP.window(ofType: Float.self, usingSequence: .hanningNormalized, count: fft_n, isHalfWindow: false)
        }()

        func FFT(signal: [Float]) -> (Float, Float) {
            var dBbuffer: [Float] = []
            var devbuffer: [Float] = []
            let padinput = signal + [Float](repeating: 0, count: fft_n - signal.count % fft_n)
            var amplitudeSpectrum = [Float](repeating: 0.0, count: fft_n)
            var inputReal = [Float](repeating: 0.0, count: fft_n)
            var inputImag = [Float](repeating: 0.0, count: fft_n)
            var outputReal = [Float](repeating: 0.0, count: fft_n)
            var outputImag = [Float](repeating: 0.0, count: fft_n)
            inputReal.withUnsafeMutableBufferPointer { inputRealPtr in
                inputImag.withUnsafeMutableBufferPointer { inputImagPtr in
                    outputReal.withUnsafeMutableBufferPointer { outputRealPtr in
                        outputImag.withUnsafeMutableBufferPointer { outputImagPtr in
                            var output = DSPSplitComplex(realp: outputRealPtr.baseAddress!, imagp: outputImagPtr.baseAddress!)
                            for i in stride(from: 0, to: signal.count, by: fft_n) {
                                vDSP.add(multiplication: (a: padinput[i..<i+fft_n], b: window), 0, result: &inputRealPtr)
                                let input = DSPSplitComplex(realp: inputRealPtr.baseAddress!, imagp: inputImagPtr.baseAddress!)
                                fft.forward(input: input, output: &output)
                                
                                vDSP.absolute(output, result: &amplitudeSpectrum)
                                let powerSpectrum = vDSP.amplitudeToDecibels(amplitudeSpectrum, zeroReference: 1)
                                
                                let meandB = vDSP.mean(powerSpectrum[1..<fft_n/2])
                                let base = powerSpectrum[1..<fft_n/2].filter({$0 < meandB})
                                let basedB = base.reduce(0, +) / Float(base.count)
                                let dev = vDSP.meanSquare(vDSP.add(-pow(10.0, basedB/20.0), amplitudeSpectrum[1..<fft_n/2]))
                                dBbuffer.append(meandB)
                                devbuffer.append(sqrt(dev))
                            }
                        }
                    }
                }
            }
            return (vDSP.mean(dBbuffer), vDSP.maximum(devbuffer))
        }

        func process_samples(sample: [Float]) async {
            guard !sample.isEmpty else { return }
            guard parent.isRecording else { return }

            let maxAmp = sample.map({ abs($0) }).max() ?? 1.0
            if maxAmp * gain > 1.0 {
                gain = 1.0 / maxAmp
            }

            let gainedData = sample.map({ $0 * gain })
            if gainedData.allSatisfy({ $0 == 0 }) {
                parent.volLeveldB = -40
                parent.volDev = -5
            }
            else {
                let result = FFT(signal: gainedData)
                parent.volLeveldB = result.0
                parent.volDev = log10(max(result.1 / gain, 1e-6)) + 1
            }

            if parent.volLeveldB < parent.gainTargetdB {
                let newGain = pow(10.0, (parent.gainTargetdB - max(parent.volLeveldB, -120)) / 20.0) * gain
                gain = (1 - 0.25) * gain + 0.25 * newGain
                gain = min(gain, 1000)
            }

            if parent.volLeveldB > parent.silentLeveldB && parent.volDev > parent.volDevThreshold {
                scount = 0
            }
            else {
                scount += 1
            }
            parent.active = scount < contCount

            Task.detached { @MainActor in
                self.parent.timeCount += gainedData.count
            }

            if parent.active {
                buffer.append_data(data: gainedData)
                buffer.lastSound = Date()
            }
            else {
                buffer.append_preData(data: gainedData)
                if scount < contCount {
                    buffer.lastSound = Date()
                }
                else if scount == contCount {
                    parent.silenceMap[Double(parent.timeCount) / 16000] = Double(gainedData.count) / 16000
                }
                else {
                    if let lastSilence = parent.silenceMap.keys.sorted().last {
                        parent.silenceMap[lastSilence]! += Double(gainedData.count) / 16000
                    }
                    else {
                        parent.silenceMap[Double(parent.timeCount) / 16000] = Double(gainedData.count) / 16000
                    }
                }
            }

            if parent.callCount == 0 {
                let bufdata = buffer.read_buffer(internalLength: Int(parent.internalWaitTime * 16000))
                parent.waitTime = buffer.get_waittime() + parent.internalWaitTime
                if !bufdata.buf.isEmpty {
                    lastCall = Date()
                    await callTranscribe(samples: bufdata.buf, transrate: parent.transrate)
                    lastCall = Date()
                }
                else if lastCall.timeIntervalSinceNow < -10, parent.internalWaitTime > 28 * 1000 {
                    lastCall = Date()
                    await callTranscribe(samples: [], transrate: parent.transrate)
                    lastCall = Date()
                }

                if parent.internalWaitTime > 0, bufdata.flush {
                    while parent.internalWaitTime > 0 {
                        lastCall = Date()
                        await callTranscribe(samples: [], transrate: parent.transrate)
                        lastCall = Date()
                    }
                    await parent.whisperContext?.clear()
                }
            }
            parent.waitTime = buffer.get_waittime() + parent.internalWaitTime
        }

        func finish_process() async {
            let buf = buffer.flush_buffer()
            parent.waitTime = buffer.get_waittime() + parent.internalWaitTime
            await callTranscribe(samples: buf, transrate: parent.transrate)

            while parent.internalWaitTime > 0 {
                lastCall = Date()
                await callTranscribe(samples: [], transrate: parent.transrate)
                lastCall = Date()
            }
            await parent.whisperContext?.clear()
            parent.waitTime = buffer.get_waittime() + parent.internalWaitTime
            parent.logBuffer = logBuffer
        }

        private func callTranscribe(samples: [Float], transrate: Bool) async {
            if (!parent.isModelLoaded) {
                return
            }
            guard let whisperContext = parent.whisperContext else {
                return
            }

            parent.internalWaitTime = await Double(whisperContext.waitTime) / 16000
            OSAtomicIncrement64(&parent.callCount)
            defer {
                OSAtomicDecrement64(&parent.callCount)
            }
            guard await whisperContext.isLive else { return }
            let txt = await whisperContext.fullTranscribe(samples: samples, fixlang: parent.fixLanguage, transrate: transrate, language_thold: Float(parent.languageCutoff), lang_callback: { lang in
                self.parent.language = lang
            })
            if !txt.isEmpty {
                logBuffer = logBuffer.merging(txt) { $1 }
                let keys = filterTimeKey(Array(logBuffer.keys))
                logBuffer = logBuffer.filter({ keys.contains($0.key) })
            }
            guard await whisperContext.isLive else { return }
            buffer.done_processing(sample_count: samples.count)
            parent.internalWaitTime = await Double(whisperContext.waitTime) / 16000
            if !txt.isEmpty {
                Task.detached { @MainActor [self] in
                    let buf = await logBuffer
                    let v = buf.keys.sorted(by: { $0.start < $1.start }).map({ (buf[$0]!, Double($0.start) / 16000) })
                    parent.messageLog = v.map(\.0)
                    parent.messageTiming = v.map(\.1).map(parent.fixTimestamp)
                }
            }
        }
    }
    var processer: Processer?

    func toggleRecord() async -> Bool {
        if isRecording, isPlaying {
            await togglePlay(file: URL(fileURLWithPath: ""))
        }
        Task.detached { @MainActor [self] in
            isPlaying = false
        }
        if isRecording {
            Task.detached { @MainActor [self] in
                isProcessing = true
            }
            recorder.stopRecording()
            active = false
            volLeveldB = -40
            volDev = 0

            while recorder.recording {
                try? await Task.sleep(for: .milliseconds(100))
            }

            await processer?.finish_process()

            await processer?.stop()
            Task.detached { @MainActor [self] in
                isRecording = recorder.recording
                processer = nil
#if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
#endif
                isProcessing = false
            }
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                print("notDetermined")
                if await !AVCaptureDevice.requestAccess(for: .audio) {
                    print("failed")
                    return false
                }
            case .restricted:
                print("restricted")
                return false
            case .denied:
                print("denied")
                return false
            case .authorized:
                print("granted")
            @unknown default:
                fatalError()
            }
            callCount = 0
            processer = Processer(parent: self)
            Task.detached { @MainActor [self] in
                isProcessing = true
#if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = true
#endif
                if timeCount == 0 {
                    messageLog.removeAll()
                }
            }
            recorder.startRecording { [self] data in
                Task.detached { [self] in
                    await processer?.process_samples(sample: data)
                }
                Task.detached { @MainActor [self] in
                    currentGain = await Double(processer?.gain ?? 1.0)
                }
            }
            Task.detached { @MainActor [self] in
                isRecording = recorder.recording
                isProcessing = false
            }
        }
        return true
    }

    func togglePlay(file: URL) async {
        if isRecording, !isPlaying {
            _ = await toggleRecord()
        }
        Task.detached { @MainActor [self] in
            isPlaying = true
        }
        if isRecording {
            Task.detached { @MainActor [self] in
                isProcessing = true
            }
            player.stopRecording()
            active = false
            volLeveldB = -40
            volDev = 0

            while player.recording {
                try? await Task.sleep(for: .milliseconds(100))
            }

            await processer?.finish_process()

            await processer?.stop()
            Task.detached { @MainActor [self] in
                isRecording = player.recording
                processer = nil
#if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
#endif
                isProcessing = false
            }
        } else {
            callCount = 0
            processer = Processer(parent: self)
            Task.detached { @MainActor [self] in
                isProcessing = true
#if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = true
#endif
                if timeCount == 0 {
                    messageLog.removeAll()
                }
            }
            player.startRecording(file: file) { [self] data in
                if data.isEmpty {
                    Task.detached { [self] in
                        await processer?.finish_process()
                        
                        await processer?.stop()
                        Task.detached { @MainActor [self] in
                            active = false
                            volLeveldB = -40
                            volDev = 0

                            isRecording = player.recording
                            processer = nil
#if os(iOS)
                            UIApplication.shared.isIdleTimerDisabled = false
#endif
                            isProcessing = false
                        }
                    }
                }
                Task.detached { [self] in
                    await processer?.process_samples(sample: data)
                }
                Task.detached { @MainActor [self] in
                    currentGain = await Double(processer?.gain ?? 1.0)
                }
            }
            Task.detached { @MainActor [self] in
                isRecording = player.recording
                isProcessing = false
            }
        }
    }
}
    
 

