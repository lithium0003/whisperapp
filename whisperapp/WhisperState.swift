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

class WhisperState: NSObject, ObservableObject {
    let model_size: String
    @Published var isModelLoaded = false
    @Published var isRecording = false
    @Published var fixLanguage = "auto"
    @Published var transrate = false
    @Published var messageLog: [String] = []

    var active = false
    var waitTime = 0.0
    var callCount = 0
    var language = ""
    var languageCutoff = 0.5
    var volLeveldB: Float = -80
    var silentLeveldB: Float = -35
    
    @Published var bufferSec = 30
    @Published var contCount = 5

    var languageList: [String] {
        if let list = whisperContext?.languageList {
            return ["auto"] + list
        }
        return ["auto"]
    }
    
    private var whisperContext: WhisperContext?
    private var recorder = Recorder()

    private var modelUrl: URL? {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let models = cache.appending(path: "models")
        let index = models.appending(path: "index").appending(path: "\(model_size)")
        guard let data = try? String(contentsOf: index) else {
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
    
    private func loadModel() {
        Task.detached { @MainActor [self] in
            messageLog.append("Loading model...")
        }
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
                            let context = try WhisperContext.createContext(path: modelUrl.path())

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
                            messageLog.append(contentsOf: log.split(whereSeparator: \.isNewline).map({ String($0) }))
                        }
                    }
                    Task.detached { @MainActor [self] in
                        messageLog.append("Loaded model \(modelUrl.lastPathComponent)")
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
        private var gain: Float = 1.0
        private let contCount: Int
        private var scount: Int
        private var callid = 0

        actor LogBuffer {
            private var buf: [Int: [String]] = [:]
            private var isOpen: [Int] = []
            private let parent: WhisperState

            init(parent: WhisperState) {
                self.parent = parent
            }
            
            func start(callid: Int) {
                isOpen.append(callid)
                buf[callid] = []
            }
            
            func add(callid: Int, log: [String]) {
                if callid == isOpen.min() {
                    Task.detached { @MainActor [self] in
                        parent.messageLog.append(contentsOf: log)
                    }
                }
                else {
                    buf[callid]?.append(contentsOf: log)
                }
            }
            
            func close(callid: Int) {
                isOpen.removeAll(where: { $0 == callid })
                var sendLog: [String] = []
                for key in buf.keys.sorted() {
                    if isOpen.contains(key) {
                        break
                    }
                    if let curbuf = buf[key] {
                        sendLog.append(contentsOf: curbuf)
                        buf[key] = nil
                    }
                }
                let log = sendLog
                Task.detached { @MainActor [self] in
                    parent.messageLog.append(contentsOf: log)
                }
            }
        }
        
        class SoundBuffer {
            private var soundBuffer: [Int: [Float]] = [:]
            private var preBuffer: [Float] = []
            private var rIdx = 0
            private var wIdx = 0
            private let callLength: Int
            private let contCount: Int
            private var processing_samples = 0
            private(set) var last_process = Date()

            init(callLength: Int, contCount: Int) {
                self.callLength = callLength
                self.contCount = contCount
            }
            
            func done_processing(sample_count: Int) {
                processing_samples -= sample_count
            }
            
            func get_waittime() -> Double {
                let flatten = soundBuffer.compactMap({ $0.value.count }).reduce(0, +)
                return Double(flatten + processing_samples) / 16000
            }
            
            func clear() {
                soundBuffer.removeAll()
            }
            
            func append_preData(data: [Float]) {
                preBuffer.append(contentsOf: data)
                if preBuffer.count > 16000 {
                    preBuffer.removeFirst(preBuffer.count - 16000)
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
                if soundBuffer[wIdx] == nil {
                    soundBuffer[wIdx] = fixData
                }
                else {
                    soundBuffer[wIdx]!.append(contentsOf: fixData)
                }
                last_process = Date()
            }
            
            func rotate_buffer(remove_last: Bool) {
                if remove_last {
                    let rmlen = 1600 * 2 * (contCount - 1)
                    if rmlen > 0, soundBuffer[wIdx]?.count ?? 0 > rmlen {
                        soundBuffer[wIdx]?.removeLast(rmlen)
                    }
                }
                if soundBuffer[wIdx] != nil {
                    wIdx += 1
                }
            }
            
            func find_breakpoint(buf: [Float]) -> Int {
                let blockLen = min(buf.count, callLength) / 1600
                let powers = (blockLen*3/4..<blockLen).map({ i in
                    (block: i, power: vDSP.meanMagnitude(buf[i*1600..<(i+1)*1600]))
                })
                return (powers.min(by: { $0.power < $1.power }).map({ $0.block }) ?? 0) * 1600
            }
            
            func read_buffer() -> [Float] {
                if let first = soundBuffer[rIdx], first.count >= callLength {
                    let buf = first
                    let i = find_breakpoint(buf: buf)
                    if i > 0 {
                        soundBuffer[rIdx]?.removeFirst(i)
                        processing_samples += i
                        return Array(buf[0..<i])
                    }
                    else {
                        if rIdx < wIdx {
                            soundBuffer[rIdx] = nil
                            rIdx += 1
                        }
                        else {
                            soundBuffer[rIdx]?.removeAll()
                        }
                        processing_samples += buf.count
                        return buf
                    }
                }
                else if let first = soundBuffer[rIdx], (rIdx < wIdx || last_process.timeIntervalSinceNow < -0.2 * Double(contCount * 2)) {
                    if !first.isEmpty {
                        let buf = first
                        soundBuffer[rIdx] = nil
                        if rIdx < wIdx {
                            rIdx += 1
                        }
                        processing_samples += buf.count
                        return buf
                    }
                    soundBuffer[rIdx] = nil
                    if rIdx < wIdx {
                        rIdx += 1
                    }
                }
                if soundBuffer[rIdx] == nil {
                    if rIdx < wIdx {
                        rIdx += 1
                    }
                }
                return []
            }
        }
        private var buffer: SoundBuffer
        private let parent: WhisperState
        private var logbuffer: LogBuffer
        
        init(parent: WhisperState) {
            self.parent = parent
            self.contCount = parent.contCount
            self.buffer = SoundBuffer(callLength: 16000 * parent.bufferSec, contCount: contCount)
            self.logbuffer = LogBuffer(parent: parent)
            self.scount = contCount
        }
        
        let fft_n = 512
        lazy var fft = {
            let log2n = vDSP_Length(log2(Float(fft_n)) + 1)
            let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
            return fft
        }()

        func FFT(signal: [Float]) -> Float {
            var dBmean: [Float] = []
            var padinput = signal + [Float](repeating: 0, count: fft_n - signal.count % fft_n)
            var amplitudeSpectrum = [Float](repeating: 0.0, count: fft_n)
            padinput.withUnsafeMutableBufferPointer { inputRealPtr in
                var inputImag = [Float](repeating: 0.0, count: fft_n)
                var outputReal = [Float](repeating: 0.0, count: fft_n)
                var outputImag = [Float](repeating: 0.0, count: fft_n)
                inputImag.withUnsafeMutableBufferPointer { inputImagPtr in
                    outputReal.withUnsafeMutableBufferPointer { outputRealPtr in
                        outputImag.withUnsafeMutableBufferPointer { outputImagPtr in
                            var output = DSPSplitComplex(realp: outputRealPtr.baseAddress!, imagp: outputImagPtr.baseAddress!)
                            for i in stride(from: 0, to: signal.count, by: fft_n) {
                                let input = DSPSplitComplex(realp: inputRealPtr.baseAddress!.advanced(by: i), imagp: inputImagPtr.baseAddress!)
                                fft.forward(input: input, output: &output)
                                
                                vDSP.absolute(output, result: &amplitudeSpectrum)
                                let powerSpectrum = vDSP.amplitudeToDecibels(amplitudeSpectrum, zeroReference: 1)

                                dBmean.append(vDSP.mean(powerSpectrum[1..<fft_n/2]))
                            }
                        }
                    }
                }
            }
            return vDSP.mean(dBmean)
        }
        
        func process_samples(sample: [Float]) {
            guard !sample.isEmpty else { return }
            guard parent.isRecording else { return }
            
            let gainedData = sample.map({ $0 * gain })
            parent.volLeveldB = FFT(signal: gainedData)

            if parent.volLeveldB < -70 {
                let newGain = pow(10.0, (-70 - parent.volLeveldB) / 20.0) * gain
                gain = (1 - 0.001) * gain + 0.001 * newGain
            }
            if parent.volLeveldB > 0 {
                let newGain = pow(10.0, (0 - parent.volLeveldB) / 20.0) * gain
                gain = min(gain, newGain)
            }

            if parent.volLeveldB > parent.silentLeveldB {
                scount = 0
            }
            else {
                scount += 1
            }
            parent.active = scount < contCount

            if parent.active {
                buffer.append_data(data: gainedData)
            }
            else {
                buffer.append_preData(data: gainedData)
                if scount >= contCount {
                    buffer.rotate_buffer(remove_last: true)
                }
            }

            let buf = buffer.read_buffer()
            if !buf.isEmpty {
                callTranscribe(samples: buf, transrate: parent.transrate)
            }
            
            parent.waitTime = buffer.get_waittime()
        }

        private func callTranscribe(samples: [Float], transrate: Bool) {
            if samples.isEmpty {
                return
            }
            if (!parent.isModelLoaded) {
                return
            }
            guard let whisperContext = parent.whisperContext else {
                return
            }
            let curCall = callid
            callid += 1
            Task.detached { [self] in
                await logbuffer.start(callid: curCall)
                parent.callCount += 1
                let txt = await whisperContext.fullTranscribe(samples: samples, fixlang: parent.fixLanguage, transrate: transrate, language_thold: Float(parent.languageCutoff), lang_callback: { lang in
                    self.parent.language = lang
                })
                await logbuffer.add(callid: curCall, log: txt)
                await buffer.done_processing(sample_count: samples.count)
                parent.callCount -= 1
                parent.waitTime = await buffer.get_waittime()
                await logbuffer.close(callid: curCall)
            }
        }
    }
    var processer: Processer?
    
    func toggleRecord() async {
        if isRecording {
            await recorder.stopRecording()
            active = false
            volLeveldB = -80
            Task.detached { @MainActor [self] in
                isRecording = false
                processer = nil
            }
        } else {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
                print("undetermined")
                if await !AVAudioApplication.requestRecordPermission() {
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
            processer = Processer(parent: self)
            Task.detached { @MainActor [self] in
                messageLog.removeAll()
                isRecording = true
            }
            do {
                try await recorder.startRecording { [self] data in
                    Task.detached { [self] in
                        await processer!.process_samples(sample: data)
                    }
                }
            }
            catch {
                print(error)
                Task.detached { @MainActor [self] in
                    isRecording = false
                }
            }
        }
    }
}
 
