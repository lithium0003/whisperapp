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
    @State var timeStamp = true

    var body: some View {
        VStack {
            HStack {
                ShareLink(item: resultText)
                Spacer()
                if timeStamp {
                    Button {
                        timeStamp = false
                        resultText = resultText.split(separator: "\n\n").map({ $0.split(separator: "\n").dropFirst(2).joined(separator: "\n") }).joined(separator: "\n")
                    } label: {
                        Text("to Plain Text")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    exporterPresented = true
                } label: {
                    Image(systemName: "doc")
                    Text("Save")
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
