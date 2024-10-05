//
//  EditView.swift
//  whisperapp
//
//  Created by rei9 on 2024/09/23.
//



import SwiftUI

struct EditView: View {
    @EnvironmentObject var userData: StateHolder
    @State var resultText = ""
    @State var exporterPresented = false

    var body: some View {
        VStack {
            HStack {
                ShareLink(item: resultText)
                Spacer()
                Button {
                    exporterPresented = true
                } label: {
                    Image(systemName: "doc")
                }
                Spacer()
                Button("Done") {
                    userData.presentedPage.removeLast()
                }
            }
            .padding()
            TextEditor(text: $resultText)
        }
        .fileExporter(isPresented: $exporterPresented,
                      document: TextFile(initialText: resultText),
                      contentType: .plainText,
                      defaultFilename: "Untitled.txt",
                      onCompletion: { result in
            switch result {
            case .success(let url):
                print("success to save \(url)")
            case .failure(let error):
                print(error.localizedDescription)
            }
        })
    }
}

#Preview {
    EditView()
}
