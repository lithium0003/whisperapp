//
//  RootView.swift
//  whisperapp
//
//  Created by rei9 on 2024/09/23.
//


import SwiftUI

struct RootView: View {
    @EnvironmentObject var userData: StateHolder
    
    var body: some View {
        switch userData.presentedPage.last {
        case .main:
            ContentView(whisperState: $userData.whisperState)
        case .edit(let text):
            EditView(resultText: text)
        case .config:
            ConfigView(whisperState: $userData.whisperState)
        case .none:
            ModelSelecter()
        }
    }
}

#Preview {
    RootView()
}
