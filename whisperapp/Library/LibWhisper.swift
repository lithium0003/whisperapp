//
//  LibWhisper.swift
//  whisper
//
//  Created by rei9 on 2024/04/17.
//
import Foundation
import whisper
import SwiftUI
import Accelerate

enum WhisperError: Error {
    case couldNotInitializeContext
}

struct TimeKey: Hashable {

    let start: Int
    let stop: Int
    let logProbSum: Double
    let tokenCount: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.start)
        hasher.combine(self.stop)
        hasher.combine(self.logProbSum)
        hasher.combine(self.tokenCount)
    }

    static func ==(lhs: TimeKey, rhs: TimeKey) -> Bool {
        return lhs.start == rhs.start && lhs.stop == rhs.stop && lhs.logProbSum == rhs.logProbSum && lhs.tokenCount == rhs.tokenCount
    }
}

func filterTimeKey(_ keys: [TimeKey]) -> [TimeKey] {
    let overlap = keys.map({ a in
        let o = keys.filter({ $0 != a }).filter({ b in
            a.start <= b.stop && a.stop >= b.start
        })
        if o.isEmpty { return (value: 0.0, total: 0.0) }
        let overlap = o.map({ min(a.stop, $0.stop) - max(a.start, $0.start) })
        let total = o.map({ $0.stop - $0.start })
        let ratio = zip(overlap, total).map({ Double(max(0, $0)) / Double($1) })
        return (value: zip(o, ratio).reduce(0.0, { $0 + pow(10, $1.0.logProbSum / Double($1.0.tokenCount)) * $1.1 }), total: overlap.reduce(0.0, { $0 + Double($1) / 16000 }))
    })
    let winKeys = zip(keys, overlap).sorted(by: { (arg0, arg1) in
        let (a0, a1) = arg0
        let (b0, b1) = arg1
        let at = Double(a0.stop - a0.start) / 16000
        let bt = Double(b0.stop - b0.start) / 16000
        let alen = Double(a0.tokenCount) / Double(a0.tokenCount + b0.tokenCount)
        let blen = Double(b0.tokenCount) / Double(a0.tokenCount + b0.tokenCount)
        let a = (pow(10, a0.logProbSum / Double(a0.tokenCount)) * at - a1.value * a1.total) / (at + a1.total) * alen
        let b = (pow(10, b0.logProbSum / Double(b0.tokenCount)) * bt - b1.value * b1.total) / (bt + b1.total) * blen
        return a > b }).map(\.0)
    var winner: [TimeKey] = []
    for a in winKeys {
        if winner.isEmpty {
            winner.append(a)
            continue
        }
        if winner.contains(where: { a.start <= $0.stop - 1600 * 3 && a.stop >= $0.start + 1600 * 3 }) {
            continue
        }
        winner.append(a)
    }
    return winner.sorted(by: { $0.start < $1.start })
}

func margeTimeKeys(_ keys1: [TimeKey], _ keys2: [TimeKey]) -> [TimeKey] {
    var keys: [TimeKey] = []
    var needMergeKeys: [TimeKey] = []
    for a in keys1 {
        var pass = true
        for b in keys2 {
            if a.start > b.stop || a.stop < b.start {
                continue
            }
            pass = false
            break
        }
        if pass {
            keys.append(a)
        }
        else {
            needMergeKeys.append(a)
        }
    }
    for a in keys2 {
        var pass = true
        for b in keys1 {
            if a.start > b.stop || a.stop < b.start {
                continue
            }
            pass = false
            break
        }
        if pass {
            keys.append(a)
        }
        else {
            needMergeKeys.append(a)
        }
    }
    
    return (keys + filterTimeKey(needMergeKeys)).sorted(by: { $0.start < $1.start })
}

// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer
    var isLive = true
    var isRunning = false
    let languageList: [String]
    @AppStorage("noSpeechThold") var noSpeechThold = 0.6
    @AppStorage("temperature") var temperature = 1.0
    @AppStorage("segmentProbThold") var segmentProbThold = 0.4

    init?(path: String, params: whisper_context_params) {
        let context = whisper_init_from_file_with_params(path, params)
        guard let contect = context else { return nil }
        self.context = contect
        var languageList: [String] = []
        let lang_max_id = whisper_lang_max_id()
        for lang_id in 0..<lang_max_id {
            let lang = String.init(cString: whisper_lang_str_full(lang_id))
            languageList.append(lang)
        }
        self.languageList = languageList
    }

    deinit {
        isLive = false
        whisper_free(context)
    }

    func kill() {
        isLive = false
    }
    
    @AppStorage("silentLevel") private var silentLeveldB = -10.0
    private var voiceThreshold: Float {
        Float(silentLeveldB - 20)
    }
    private var backPoint = 0
    private var backWav = [Float]()
    private var processPoint = 0
    private var lastSegmentLog = [TimeKey]()
    var waitTime: Int {
        (backWav.lastIndex(where: { $0 != 0 }) ?? 0) + backPoint - processPoint
    }
    
    func clear() {
        backPoint += backWav.lastIndex(where: { $0 != 0 }) ?? 0
        if backPoint < 0 {
            backPoint = 0
        }
        backWav = []
        processPoint = backPoint
    }

    func reset() {
        backPoint = 0
        processPoint = 0
    }
    
    func fullTranscribe(samples: [Float], fixlang: String = "auto", transrate: Bool = false, language_thold: Float, lang_callback: ((String)->Void)?) -> [TimeKey: AttributedString] {
        var result: [TimeKey: AttributedString] = [:]
        let hallucinationPatch = !transrate
        guard isLive else {
            lang_callback?("")
            return result
        }
        isRunning = true
        defer {
            isRunning = false
        }

        backWav += samples
        if backWav.isEmpty {
            return result
        }
        let padlen = 16000 * 28 - backWav.count
        if padlen > 0 {
            if samples.isEmpty {
                backWav += [Float](repeating: 0, count: padlen)
            }
            else {
                backWav = [Float](repeating: 0, count: padlen) + backWav
                backPoint -= padlen
            }
        }

        let t_end = 2800
        let input_samples = Array(backWav[0..<16000*28]) + [Float](repeating: 0, count: 16000 * 2)

        let maxThreads = max(1, min(4, cpuCount()))
        print("Selecting \(maxThreads) threads")
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        fixlang.withCString { lang in
            params.print_realtime   = false
            params.print_progress   = false
            params.print_timestamps = false
            params.print_special    = false
            params.translate        = transrate
            params.language         = lang
            params.language_thold   = language_thold
            params.n_threads        = Int32(maxThreads)
            params.temperature_inc  = 0.0
            params.temperature      = Float(temperature)
            params.no_speech_thold  = Float(noSpeechThold)
            params.max_initial_ts   = Float(t_end) * 0.01
            params.beam_search.beam_size = 8
            params.entropy_thold    = 2.4
            params.suppress_blank   = false
            params.suppress_non_speech_tokens = true
            params.no_timestamps    = false
            params.single_segment   = true
            params.token_timestamps = true

            whisper_reset_timings(context)
            print("About to run whisper_full")
            input_samples.withUnsafeBufferPointer { samples in
                if (whisper_full(context, params, samples.baseAddress, Int32(samples.count)) != 0) {
                    print("Failed to run the model")
                }
                else {
                    whisper_print_timings(context);
                }
            }
        }

        let lang_id = whisper_full_lang_id(context)
        if lang_id < 0 {
            lang_callback?("(no voice)")
            var shift = samples.isEmpty ? 16000 * 10 : 0
            if backWav.count > 16000 * 60 {
                shift += 16000 * 15
            }

            if shift > 0 {
                if shift < backWav.count {
                    backPoint += shift
                    backWav.removeFirst(shift)
                }
                else {
                    backPoint += backWav.count
                    backWav.removeAll()
                }
            }

            if processPoint < backPoint {
                processPoint = backPoint
            }

            return result
        }
        else {
            lang_callback?(String.init(cString: whisper_lang_str_full(lang_id)))
        }
        let n_segments = whisper_full_n_segments(context)
        var all_probs: [Double] = []
        var segmentLog = [TimeKey]()
        for i in 0..<n_segments {
            let n_tokens = whisper_full_n_tokens(context, i)
            let t0 = whisper_full_get_segment_t0(context, i)
            let t1 = whisper_full_get_segment_t1(context, i)
            let str = String(cString: whisper_full_get_segment_text(context, i))
            print(t0,t1,t_end,str)
            if t0 > t_end - 100 {
                break
            }
            if t1 > t_end {
                break
            }
            var sound_t0 = Int(t0) * 160 + backPoint
            var sound_t1 = Int(t1) * 160 + backPoint
            
            var attrStr = AttributedString(stringLiteral: str)
            attrStr.backgroundColor = .black
            let punctuation = "\"'“¿([{-\"'.。,，!！?？:：”)]}、"
            let idx = str.map({ String($0).utf8.count }).publisher.scan(0, +).sequence
            var valid = true
            var t_tw: [Int] = []
            var probs: [Double] = []
            var isPunctuation: [Bool] = []
            var sumprob = 0.0
            var logsumprob = 0.0
            var c = 0
            for j in 0..<n_tokens {
                let p = Double(whisper_full_get_token_p(context, i, j))
                let tkn = whisper_full_get_token_data(context, i, j)
                let tw = tkn.t_dtw
                probs.append(p)
                if tw >= 0 {
                    t_tw.append(Int(tw))
                }
                else if tkn.t0 >= 0, tkn.t1 >= 0 {
                    t_tw.append(Int((tkn.t0 + tkn.t1) / 2))
                }
                if let t = whisper_full_get_token_text(context, i, j) {
                    let count = strlen(t)
                    let s = idx.firstIndex(where: { $0 >= c }) ?? str.count - 1
                    let e = idx.firstIndex(where: { $0 > c+count }) ?? str.count
                    
                    let startIdx = attrStr.index(attrStr.startIndex, offsetByCharacters: s)
                    let endIdx = attrStr.index(attrStr.startIndex, offsetByCharacters: e)
                    attrStr[startIdx..<endIdx].foregroundColor = Color(red: 1, green: p, blue: 1)
                    c += count
                    
                    let startIdx2 = str.index(str.startIndex, offsetBy: s)
                    let endIdx2 = str.index(str.startIndex, offsetBy: e)

                    if punctuation.unicodeScalars.contains(str[startIdx2..<endIdx2].unicodeScalars) {
                        isPunctuation.append(true)
                    }
                    else {
                        isPunctuation.append(false)
                    }
                }
            }
            if hallucinationPatch {
                if t_tw.count > 1 {
                    var score = 0.0
                    var count = 0
                    for ((s,p),(tw0,tw1)) in zip(zip(isPunctuation,probs), zip(t_tw, t_tw.dropFirst())) {
                        if s {
                            continue
                        }
                        if tw0 <= 0 {
                            continue
                        }
                        let duration = Double(tw1 - tw0) * 0.01
                        if duration < 0 {
                            continue
                        }
                        print(count,duration)
                        if p < 0.15 {
                            score += 1.0
                        }
                        if duration < 0.0666 {
                            score += (0.0666 - duration) * 30
                        }
                        if duration > 2.0 {
                            score += duration - 2.0
                        }
                        count += 1
                        if count >= 8 {
                            break
                        }
                    }
                    if score >= 3 || score + 0.01 >= Double(count) {
                        valid = false
                    }
                    print(valid, score, str)
                }
                else if t_tw.count == 1, let p = probs.first {
                    var score = 0.0
                    let duration = Double(t1 - t0) * 0.01
                    if p < 0.15 {
                        score += 1.0
                    }
                    if duration < 0.0666 {
                        score += (0.0666 - duration) * 30
                    }
                    if duration > 2.0 {
                        score += duration - 2.0
                    }
                    if score >= 3 || score + 0.01 >= 1 {
                        valid = false
                    }
                    print(valid, score, str)
                }
                if probs.count > 0 {
                    logsumprob = probs.map({ log10($0) }).reduce(0.0, +)
                    sumprob = pow(10, logsumprob / Double(probs.count))
                    if sumprob < segmentProbThold {
                        valid = false
                    }
                    print(valid, sumprob, segmentProbThold)
                }
                if probs.count < 2, !t_tw.isEmpty {
                    if t_tw[0] < t0 || t_tw[0] > t1 {
                        valid = false
                    }
                    print(valid, t0, t_tw[0], t1)
                }
                if let t_min = t_tw.first, t_min > t1 || t_min < t0 - 300 {
                    valid = false
                }
                if let t_max = t_tw.last, t_max < t0 || t_max > t_end + 100 || t_max > t1 + 300 {
                    valid = false
                }
            }
            if !valid {
                print("skip", t_tw)
                continue
            }
            print(t_tw)
            if !t_tw.isEmpty {
                sound_t0 = t_tw.first! * 160 + backPoint
                sound_t1 = t_tw.last! * 160 + backPoint
            }
            print(sumprob,sound_t0,sound_t1,str)
            if sound_t0 < 0 || sound_t1 < 0 {
                print("skip")
                continue
            }
            result[.init(start: sound_t0, stop: sound_t1, logProbSum: logsumprob, tokenCount: probs.count)] = attrStr
            segmentLog.append(.init(start: sound_t0, stop: sound_t1, logProbSum: logsumprob, tokenCount: probs.count))
            if !probs.isEmpty {
                all_probs.append(contentsOf: probs)
            }
        }
        if hallucinationPatch, !all_probs.isEmpty {
            let sumprob = pow(10, all_probs.map({ log10($0) }).reduce(0.0, +) / Double(all_probs.count))
            let lowProbCount = all_probs.filter({ $0 < segmentProbThold }).count
            print(sumprob, lowProbCount)
            if lowProbCount > (all_probs.count + 2) / 3, sumprob < segmentProbThold {
                print("ignore")
                result.removeAll()
                segmentLog.removeAll()
            }
        }
        lastSegmentLog = margeTimeKeys(segmentLog, lastSegmentLog)
        if let lastStop = lastSegmentLog.last(where: { $0.start < backPoint + 16000 * 25 })?.stop {
            processPoint = lastStop
        }
        
        var shift = samples.isEmpty ? 16000 * 10 : samples.count
        if backWav.count - shift > 16000 * 60 {
            shift += 16000 * 15
        }
        
        if !samples.isEmpty {
            if let bt1 = lastSegmentLog.first(where: { $0.start < backPoint + shift && $0.stop > backPoint + shift }) {
                shift = bt1.stop + 160 * 15 - backPoint
            }
            else if let bt2 = lastSegmentLog.filter({ $0.start > backPoint }).last(where: { $0.start < backPoint + shift }) {
                shift = bt2.stop + 160 * 15 - backPoint
            }
        }

        if shift > 0 {
            if samples.isEmpty, padlen > 0, shift > padlen {
                backPoint += backWav.count - padlen
                backWav.removeAll()
            }
            else {
                if shift < backWav.count {
                    backPoint += shift
                    backWav.removeFirst(shift)
                }
                else {
                    backPoint += backWav.count
                    backWav.removeAll()
                }
            }
        }

        if processPoint < backPoint {
            processPoint = backPoint
        }
        if result.isEmpty {
            lang_callback?("")
        }
        print(Double(backPoint) / 16000, Double(processPoint) / 16000)
        return result
    }

    static func createContext(path: String, model: String) throws -> WhisperContext {
        var params = whisper_context_default_params()
        params.dtw_token_timestamps = true
        switch model {
        case "tiny":
            params.dtw_aheads_preset = WHISPER_AHEADS_TINY
        case "base":
            params.dtw_aheads_preset = WHISPER_AHEADS_BASE
        case "small":
            params.dtw_aheads_preset = WHISPER_AHEADS_SMALL
        case "medium":
            params.dtw_aheads_preset = WHISPER_AHEADS_MEDIUM
        case "large-v3":
            params.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3
        case "large-v3-turbo":
            params.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3_TURBO
        default:
            break
        }
#if targetEnvironment(simulator)
        params.use_gpu = false
        print("Running on the simulator, using CPU")
#endif
        if let obj = WhisperContext(path: path, params: params) {
            return obj
        } else {
            print("Couldn't load model at \(path)")
            throw WhisperError.couldNotInitializeContext
        }
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
