//
//  whisperappApp.swift
//  whisperapp
//
//  Created by rei9 on 2024/04/25.
//

import SwiftUI

enum NavigationDestination: Hashable {
    case main(model_size: String)
    case edit(text: String)
    case config
}

class StateHolder: ObservableObject {
    @Published var presentedPage: [NavigationDestination] = [] {
        willSet {
            modelSize = switch newValue.last {
            case .main(let model_size): model_size
            case .edit, .config, .none: ""
            }
        }
    }
    @Published var modelSize = "" {
        didSet {
            if oldValue != modelSize, ["tiny", "base", "small", "medium", "large-v2", "large-v3","large-v3-turbo"].contains(modelSize) {
                if whisperState?.model_size == modelSize {
                    return
                }
                Task {
                    await whisperState?.purge()
                }
                whisperState = WhisperState(model_size: modelSize)
            }
        }
    }
    @Published var whisperState: WhisperState?
}

@main
struct whisperappApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(StateHolder())
        }
    }
}
