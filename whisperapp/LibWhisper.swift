//
//  LibWhisper.swift
//  whisper
//
//  Created by rei9 on 2024/04/17.
//

import Foundation
import whisper

enum WhisperError: Error {
    case couldNotInitializeContext
}

// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer
    var isRunning = false
    let languageList: [String]
    
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
        whisper_free(context)
    }

    func fullTranscribe(samples: [Float], fixlang: String = "auto", transrate: Bool = false, language_thold: Float, lang_callback: ((String)->Void)?) -> [String] {
        isRunning = true

        let maxThreads = max(1, min(8, cpuCount()))
        print("Selecting \(maxThreads) threads")
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        fixlang.withCString { lang in
            params.print_realtime   = true
            params.print_progress   = true
            params.print_timestamps = true
            params.print_special    = false
            params.translate        = transrate
            params.language         = lang
            params.language_thold   = language_thold
            params.no_timestamps    = false
            params.n_threads        = Int32(maxThreads)
            params.max_initial_ts   = 0

            whisper_reset_timings(context)
            print("About to run whisper_full")
            print(samples.count)
            samples.withUnsafeBufferPointer { samples in
                if (whisper_full(context, params, samples.baseAddress, Int32(samples.count)) != 0) {
                    print("Failed to run the model")
                }
                else {
                    //whisper_print_timings(context);
                }
            }

        }

        let lang_id = whisper_full_lang_id(context)
        lang_callback?(String.init(cString: whisper_lang_str_full(lang_id)))
        var result: [String] = []
        for i in 0..<whisper_full_n_segments(context) {
            result.append(String.init(cString: whisper_full_get_segment_text(context, i)))
        }
        isRunning = false
        return result
    }

    static func createContext(path: String) throws -> WhisperContext {
        var params = whisper_context_default_params()
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
