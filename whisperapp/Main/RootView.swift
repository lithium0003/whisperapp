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
        Group {
            switch userData.presentedPage.last {
            case .main:
                ContentView()
            case .edit(let text):
                EditView(resultText: text)
            case .config:
                ConfigView()
            case .none:
                ModelSelecter()
            }
        }
    }
}

#Preview {
    RootView()
}
