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
}

struct Segment {
    let time: TimeKey
    let text: String
    let probability: [Double]
}

func filterTimeKey(_ keys: [Segment]) -> [Segment] {
    let overlap = keys.map({ a in
        let o = keys.filter({ $0.time != a.time }).filter({ b in
            a.time.start <= b.time.stop && a.time.stop >= b.time.start
        })
        if o.isEmpty { return (value: 0.0, total: 0.0) }
        let overlap = o.map({ min(a.time.stop, $0.time.stop) - max(a.time.start, $0.time.start) })
        let total = o.map({ $0.time.stop - $0.time.start })
        let ratio = zip(overlap, total).map({ Double(max(0, $0)) / Double($1) })
        return (value: zip(o, ratio).reduce(0.0, { $0 + pow(10, $1.0.time.logProbSum / Double($1.0.time.tokenCount)) * $1.1 }), total: overlap.reduce(0.0, { $0 + Double($1) / 16000 }))
    })
    let winKeys = zip(keys, overlap).sorted(by: { (arg0, arg1) in
        let (a0, a1) = arg0
        let (b0, b1) = arg1
        let at = Double(a0.time.stop - a0.time.start) / 16000
        let bt = Double(b0.time.stop - b0.time.start) / 16000
        let a = (pow(10, a0.time.logProbSum / Double(a0.time.tokenCount)) * at - a1.value * a1.total) / (at + a1.total)
        let b = (pow(10, b0.time.logProbSum / Double(b0.time.tokenCount)) * bt - b1.value * b1.total) / (bt + b1.total)
        return a > b }).map(\.0)
    var winner: [Segment] = []
    for a in winKeys {
        if winner.isEmpty {
            winner.append(a)
            continue
        }
        if winner.contains(where: { min(a.time.stop, $0.time.stop) - max(a.time.start, $0.time.start) > min(1600 * 1, min(a.time.stop - a.time.start, $0.time.stop - $0.time.start) / 3) }) {
            continue
        }
        winner.append(a)
    }
    return winner.sorted(by: { $0.time.start < $1.time.start })
}

func margeTimeKeys(_ keys1: [Segment], _ keys2: [Segment]) -> [Segment] {
    var keys: [Segment] = []
    var needMergeKeys: [Segment] = []
    for a in keys1 {
        var pass = true
        for b in keys2 {
            if a.time.start > b.time.stop || a.time.stop < b.time.start {
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
            if a.time.start > b.time.stop || a.time.stop < b.time.start {
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
    
    return (keys + filterTimeKey(needMergeKeys)).sorted(by: { $0.time.start < $1.time.start })
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
    private var lastSegmentLog = [Segment]()
    var waitTime: Int {
        (backWav.lastIndex(where: { $0 != 0 }) ?? 0) + backPoint - processPoint
    }
    
    func clear() {
        backPoint = 0
        processPoint = 0
        backWav = []
    }

    func reset() {
        backPoint = 0
        processPoint = 0
        backWav = []
        lastSegmentLog.removeAll()
    }
    
    func fullTranscribe(samples: [Float], globalCount: Int, fixlang: String = "auto", transrate: Bool = false, language_thold: Float, lang_callback: ((String)->Void)?) -> [Segment] {
        var result: [Segment] = []
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
        if !samples.isEmpty {
            backPoint = globalCount - backWav.count
        }
        if backWav.isEmpty {
            return result
        }

//        print(lastSegmentLog)
//        print(backWav.count, backPoint, processPoint, globalCount, samples.count)

        if let bt1 = lastSegmentLog.filter({ $0.time.start > backPoint }).last(where: { $0.time.stop < backPoint + backWav.count - max(16000 * 15, samples.count) }) {
            let shift = bt1.time.start - 1600 * 2 - backPoint
//            print("bt1", shift, bt1.time.start, bt1.time.stop, bt1.text)
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
        }

        if backWav.last == 0 || backWav.count - samples.count >= 16000 * 28 {
            let shift = samples.isEmpty ? 16000 * 15 : min(samples.count, 16000 * 15)
//            print("shift", shift)
            if shift > 0 {
                let count = backWav.lastIndex(where: { $0 != 0 }) ?? backWav.count
                if shift < count {
                    backPoint += shift
                    backWav.removeFirst(shift)
                }
                else {
                    backPoint += count
                    backWav.removeAll()
                }
            }
        }
//        print(backPoint, processPoint)

        if processPoint < backPoint {
            processPoint = backPoint
        }

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
            params.entropy_thold    = 2.8
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
            var shift = 16000 * 15
            if backWav.count > 16000 * 30 {
                shift = 16000 * 25
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
        for i in 0..<n_segments {
            let n_tokens = whisper_full_n_tokens(context, i)
            let t0 = whisper_full_get_segment_t0(context, i)
            let t1 = whisper_full_get_segment_t1(context, i)
            let str = String(cString: whisper_full_get_segment_text(context, i))
            print(t0,t1,t_end,str)
            if t0 > t_end - 100 {
                break
            }
            // if last segment touch the end, skip it
            if t1 >= t_end {
                break
            }
            var sound_t0 = Int(t0) * 160 + backPoint
            var sound_t1 = Int(t1) * 160 + backPoint

            let punctuation = "\"'“¿([{-\"'.。,，!！?？:：”)]}、"
            let idx = str.map({ String($0).utf8.count }).publisher.scan(0, +).sequence
            let isPunctuation = str.map({ punctuation.contains($0) })
            var strProb = [Double](repeating: 0, count: idx.count)
            var valid = true
            var t_tw: [Int] = []
            var probs: [Double] = []
            var tidx: [Int] = []
            var istPunctuation = [Bool](repeating: false, count: Int(n_tokens))
            var sumprob = 0.0
            var logsumprob = 0.0
            var c = 0
            for j in 0..<n_tokens {
                let tkn = whisper_full_get_token_data(context, i, j)
                if tkn.id >= whisper_token_beg(context) {
                    continue
                }
                let p = Double(tkn.p)
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
                    c += count
                    tidx.append(c)
                }
            }
            c = 0
            for j in idx.enumerated() {
                let s = tidx.firstIndex(where: { $0 > j.element }) ?? tidx.count
                if isPunctuation[j.offset] {
                    for k in c..<s {
                        istPunctuation[k] = true
                    }
                }
                c = s
            }
            let idxPair = (0..<(idx.max() ?? 0)).map({ c in
                let s1 = idx.firstIndex(where: { $0 > c }) ?? idx.count - 1
                let s2 = tidx.firstIndex(where: { $0 > c }) ?? tidx.count - 1
                return (s1, Set([s2]))
            })
            let txtToTokenDict = Dictionary(idxPair, uniquingKeysWith: { $0.union($1) })
            for (j1, j2) in txtToTokenDict {
                var psum = 0.0
                var count = 0.0
                for k in j2 {
                    psum += log10(probs[k])
                    count += 1
                }
                if count > 0 {
                    strProb[j1] = pow(10, psum / count)
                }
            }
            if hallucinationPatch {
                if t_tw.count > 1 {
                    // drop first token because sometimes time is not accurate
                    let drop = t_tw.count > 2 ? 1 : 0
                    var score = 0.0
                    var count = 0
                    for ((s,p),(tw0,tw1)) in zip(zip(istPunctuation,probs), zip(t_tw.dropFirst(drop), t_tw.dropFirst(drop+1))) {
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
                        // shorten duration because token level but word level
                        if duration < 0.044 {
                            score += (0.044 - duration) * 45
                        }
                        if duration > 2.0 {
                            score += duration - 2.0
                        }
                        count += 1
                        if count >= 8 {
                            break
                        }
                    }
                    if score >= 6 || score + 0.01 >= Double(count) {
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
                    if duration < 0.133 {
                        score += (0.133 - duration) * 15
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
                if let t_max = t_tw.last, t_max < t0 || t_max >= t_end || t_max > t1 + 300 {
                    valid = false
                }
            }
            if !valid {
                print("skip", t_tw)
                continue
            }
            print(t_tw)
            if t_tw.count > 1 {
                sound_t0 = t_tw.first! * 160 + backPoint
                sound_t1 = t_tw.last! * 160 + backPoint
            }
            print(sumprob,sound_t0,sound_t1,str)
            if sound_t0 < 0 && sound_t1 < 0 {
                print("skip")
                continue
            }
            sound_t0 = max(0, sound_t0)
            let s = Segment(time: TimeKey(start: sound_t0, stop: sound_t1, logProbSum: logsumprob, tokenCount: probs.count), text: str, probability: strProb)
            result.append(s)
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
            }
        }

        lastSegmentLog = margeTimeKeys(result, lastSegmentLog)
        if let lastStop = lastSegmentLog.last?.time.stop {
            processPoint = lastStop
        }

        if processPoint < backPoint {
            processPoint = backPoint
        }

        if result.isEmpty {
            lang_callback?("")
            return result
        }

        print(Double(backPoint) / 16000, Double(processPoint) / 16000)
        return lastSegmentLog
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
