//
//  Downloader.swift
//  whisperapp
//
//  Created by rei9 on 2024/04/23.
//

import Foundation

class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var isDownloading = false
    @Published var message = ""
    @Published var progress = 0.0
    private var tasks: [URLSessionDownloadTask] = []
    private var handler: ((Bool)->Void)?
    private var targetList: [String] = []
    private let baseURLstr = "https://huggingface.co/lithium0003/ggml-coreml-whisper/resolve/develop240923/"

    private let sizes = [
        "tiny": 95792 * 512,
        "base": 191272 * 512,
        "small": 667392 * 512,
        "medium": 2154456 * 512,
        "large-v2": 4392824 * 512,
        "large-v3": 4398928 * 512,
        "large-v3-turbo": 2850600 * 512,
    ]

    var bytesTransferred: Int64 = 0
    var bytesExpect: Int64 = 0

    func copy_internal() {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let models = cache.appending(path: "models")
        let index = models.appending(path: "index")
        do {
            if !FileManager.default.fileExists(atPath: index.path()) {
                try FileManager.default.createDirectory(atPath: index.path(), withIntermediateDirectories: true, attributes: nil)
            }
        }
        catch {
            print(error)
            message = error.localizedDescription
            return
        }

        let tiny_index = Bundle.main.url(forResource: "tiny", withExtension: nil)
        if let tiny_index = tiny_index {
            let destUrl = index.appending(path: tiny_index.lastPathComponent)
            do {
                if !FileManager.default.fileExists(atPath: destUrl.path()) {
                    try FileManager.default.copyItem(at: tiny_index, to: destUrl)
                }
            }
            catch {
                print(error)
                message = error.localizedDescription
            }
        }
        let tiny_files = [
            Bundle.main.url(forResource: "ggml-tiny-q8_0", withExtension: "bin"),
            Bundle.main.url(forResource: "ggml-tiny-encoder", withExtension: "mlmodelc"),
        ]
        for tiny_file in tiny_files {
            if let tiny_file = tiny_file {
                let destUrl = models.appending(path: tiny_file.lastPathComponent)
                do {
                    if !FileManager.default.fileExists(atPath: destUrl.path()) {
                        try FileManager.default.copyItem(at: tiny_file, to: destUrl)
                    }
                }
                catch {
                    print(error)
                    message = error.localizedDescription
                }
            }
        }
    }

    func isDownloaded(model_size: String) -> Bool {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }
        let models = cache.appending(path: "models")
        let index = models.appending(path: "index").appending(path: "\(model_size)")
        guard let data = try? String(contentsOf: index, encoding: .utf8) else {
            return false
        }
        
        for file in data.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let path = models.appending(path: file)
            if !FileManager.default.fileExists(atPath: path.path()) {
                return false
            }
        }
        
        return true
    }
    
    func clearAll() {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let models = cache.appending(path: "models")
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: models, includingPropertiesForKeys: nil) else {
            return
        }
        print(fileURLs)
        for url in fileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    func cancel() {
        for task in tasks {
            task.cancel()
        }
        tasks = []
        message = "Cancel"
        isDownloading = false
        handler?(false)
    }
    
    lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "info.lithium03.whisper")
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    func download(model_size: String, comleate: @escaping (Bool)->Void) {
        isDownloading = true
        handler = comleate
        bytesTransferred = 0
        bytesExpect = Int64(sizes[model_size] ?? 0)
        message = "Download start"

        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            message = "Download error"
            return
        }
        let models = cache.appending(path: "models")
        let index = models.appending(path: "index")
        
        do {
            if !FileManager.default.fileExists(atPath: index.path()) {
                try FileManager.default.createDirectory(atPath: index.path(), withIntermediateDirectories: true, attributes: nil)
            }
        }
        catch {
            print(error)
            message = error.localizedDescription
            return
        }
        
        download_index(model_size: model_size)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        tasks = tasks.filter({ $0.taskIdentifier != downloadTask.taskIdentifier })
        print("download", downloadTask.originalRequest?.url?.absoluteString ?? "")
        
        if let url = downloadTask.originalRequest?.url?.absoluteString {
            let filepath = url.replacingOccurrences(of: baseURLstr, with: "")
            
            let modelUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appending(path: "models")
            
            let destUrl = modelUrl.appending(path: filepath)
            let parent = destUrl.deletingLastPathComponent()
            do {
                if !FileManager.default.fileExists(atPath: parent.path()) {
                    try FileManager.default.createDirectory(atPath: parent.path(), withIntermediateDirectories: true, attributes: nil)
                }
                if FileManager.default.fileExists(atPath: destUrl.path()) {
                    try FileManager.default.removeItem(at: destUrl)
                }
                try FileManager.default.moveItem(at: location, to: destUrl)
            }
            catch {
                print(error)
                Task.detached { @MainActor in
                    self.message = error.localizedDescription
                }
                return
            }
            
            if filepath.starts(with: "index") {
                let model_size = filepath.replacingOccurrences(of: "index/", with: "")
                process_index(model_size: model_size)
            }
            else {
                check_index()
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task.detached { @MainActor [self] in
            bytesTransferred += bytesWritten
            progress = min(1, Double(bytesTransferred) / Double(bytesExpect))
            message = "\(bytesTransferred.formatted(.number.grouping(.automatic))) / \(bytesExpect.formatted(.number.grouping(.automatic))) (\((progress * 100).formatted(.number.precision(.fractionLength(2))))%)"
        }
    }
    
    func download_index(model_size: String) {
        guard let urlBase = URL(string: baseURLstr) else {
            Task.detached { @MainActor in
                self.message = "Download error"
            }
            return
        }
        let indexUrl = urlBase.appending(component: "index").appending(component: model_size)
        
        let backgroundTask = urlSession.downloadTask(with: indexUrl)
        tasks.append(backgroundTask)
        backgroundTask.countOfBytesClientExpectsToSend = 200
        backgroundTask.countOfBytesClientExpectsToReceive = 500 * 1024
        backgroundTask.resume()
        message = "Download index"
    }
    
    func download_file(file: String) {
        guard let urlBase = URL(string: baseURLstr) else {
            Task.detached { @MainActor in
                self.message = "Download error"
            }
            return
        }
        let targetUrl = urlBase.appending(path: file)
        
        let backgroundTask = urlSession.downloadTask(with: targetUrl)
        tasks.append(backgroundTask)
        backgroundTask.countOfBytesClientExpectsToSend = 200
        backgroundTask.resume()
    }
    
    func process_index(model_size: String) {
        let modelUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appending(path: "models")
        let indexUrl = modelUrl.appending(path: "index").appending(path: model_size)
        guard let data = try? String(contentsOf: indexUrl, encoding: .utf8) else {
            Task.detached { @MainActor in
                self.message = "Download error: index file not found"
            }
            handler?(false)
            return
        }
        targetList = data.components(separatedBy: .newlines)
        
        var downloaded = 0
        var needrequest = 0
        for file in targetList {
            let path = modelUrl.appending(path: file)
            if FileManager.default.fileExists(atPath: path.path()) {
                downloaded += 1
                bytesTransferred += try! FileManager.default.attributesOfItem(atPath: path.path())[.size] as! Int64
            }
            else {
                needrequest += 1
                download_file(file: file)
            }
        }
        
        if downloaded > 0, needrequest == 0 {
            Task.detached { @MainActor in
                self.isDownloading = false
            }
            handler?(true)
        }
    }
    
    func check_index() {
        let modelUrl = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appending(path: "models")

        var downloaded = 0
        var needrequest = 0
        for file in targetList {
            let path = modelUrl.appending(path: file)
            if FileManager.default.fileExists(atPath: path.path()) {
                downloaded += 1
            }
            else {
                needrequest += 1
            }
        }

        if downloaded > 0, needrequest == 0 {
            Task.detached { @MainActor in
                self.isDownloading = false
            }
            handler?(true)
        }
    }
    
    
}
