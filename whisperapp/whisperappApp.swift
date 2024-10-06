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
        willSet {
            if newValue != modelSize, newValue != "" {
                if whisperState?.model_size == newValue {
                    return
                }
                Task {
                    await whisperState?.purge()
                }
                whisperState = WhisperState(model_size: newValue)
            }
        }
    }
    @Published var whisperState: WhisperState!
}

@main
struct whisperappApp: App {
    @StateObject var stateHolder = StateHolder()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(stateHolder)
        }
    }
}
