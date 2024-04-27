//
//  ContentView.swift
//  whisper
//
//  Created by rei9 on 2024/04/17.
//

import SwiftUI

struct TextData: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text)
    }

    public var text: String
    public var caption: String
}

struct BoundsPreferenceKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = [] // << use something persistent

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf:nextValue())
    }
}

extension View {
    func reverseMask<Content: View>(alignment: Alignment = .center, _ content: () -> Content) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: alignment) {
                    content()
                        .blendMode(.destinationOut)
                }
        }
    }
}

struct ContentView: View {
    @StateObject var whisperState: WhisperState
    @State var threshold = 0.5
    @State var showConfig = false
    @State var showEdit = false
    @State var resultText = ""
    @State var exporterPresented = false
    @State var showingAlert = false
    
    @AppStorage("bufferSec") var bufferSec = 10
    @AppStorage("contCount") var contCount = 4
    @AppStorage("silentLevel") var silentLeveldB = -45.0
    @AppStorage("language") var language = "auto"
    @AppStorage("languageCutoff") var languageCutoff = 0.0
    @AppStorage("tutorial") var tutorial = 0

    let timer = Timer.publish(every: 0.2, on: .current, in: .common).autoconnect()
    @State var volLeveldB = -80.0
    @State var active = false
    @State var waitTime = 0.0
    @State var callCount = 0
    @State var detectLanguage = ""
    @State var stateLog = ""
    @State var spotlighting = false
    @State var counter = 0

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    struct VolumeView : View {
        var volume: Double
        var active: Bool

        init(volume: Double, active: Bool){
            self.volume = volume
            self.active = active
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("\(volume, format: .number.precision(.fractionLength(1)))dB")
                        .font(.subheadline.monospacedDigit())
                        .padding(5)
                    if active {
                        Text("Detection active")
                            .foregroundStyle(Color.red)
                    }
                    else {
                        Text("(in silence)")
                    }
                    Spacer()
                }
                Rectangle()
                    .foregroundStyle(Color.clear)
                    .frame(height: 5)
                    .background(LeftPart(pct: CGFloat(volume + 80)/80).fill(active ? .red : .gray))
            }
        }

        struct LeftPart: Shape {
            let pct: CGFloat

            func path(in rect: CGRect) -> Path {
                var p = Path()
                p.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.size.width * pct, height: rect.size.height), cornerSize: .zero)
                return p
            }
        }
    }

    struct ThresholdView : View {
        var volume: Double

        init(volume: Double){
            self.volume = volume
        }

        var body: some View {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .foregroundStyle(Color.clear)
                        .frame(height: 5)
                        .background(LeftPart(pct: CGFloat(volume + 80)/80).fill(.green))
                    HStack {
                        Spacer()
                        Text("\(volume, format: .number.precision(.fractionLength(1)))dB")
                            .font(.subheadline.monospacedDigit())
                            .padding(.horizontal, 5)
                    }
                }
                HStack {
                    Spacer()
                    Text("Silence threshold")
                }
            }
        }

        struct LeftPart: Shape {
            let pct: CGFloat

            func path(in rect: CGRect) -> Path {
                var p = Path()
                p.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.size.width * pct, height: rect.size.height), cornerSize: .zero)
                return p
            }
        }
    }

    var body: some View {
        VStack {
            if whisperState.isModelLoaded {
                HStack {
                    if callCount > 0 {
                        Text("\(callCount) calls")
                    }
                    if waitTime > 0 {
                        Text("\(waitTime, format: .number.precision(.fractionLength(2))) sec wait")
                    }
                    Text(String(localized: String.LocalizationValue(detectLanguage)))
                }
                .foregroundStyle(callCount == 0 ? .primary: Color.orange)
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(0..<whisperState.messageLog.count, id: \.self) { i in
                            Text(verbatim: whisperState.messageLog[i])
                                .frame(maxWidth: .infinity, alignment: .leading).id(i)
                                .onTapGesture{}
                                .onLongPressGesture(minimumDuration: 0.5) {
                                    showEdit = true
                                }
                        }
                        Text(stateLog).frame(maxWidth: .infinity, alignment: .leading).id(-1)
                    }
                }
                .onChange(of: whisperState.messageLog.count) { oldValue, newValue in
                    reader.scrollTo(-1)
                }
            }
            if whisperState.isModelLoaded {
                VolumeView(volume: volLeveldB, active: active)
                ThresholdView(volume: silentLeveldB)
                Spacer()
                ZStack {
                    HStack {
                        Button(action: {
                            showConfig.toggle()
                        }, label: {
                            Image(systemName: "gear")
                                .font(.largeTitle)
                        })
                        .disabled(whisperState.isRecording)

                        Button(action: {
                            whisperState.transrate.toggle()
                        }, label: {
                            if whisperState.transrate {
                                Text("in English")
                            }
                            else {
                                Text("transcribe")
                            }
                        })
                        .disabled(whisperState.isRecording)

                        Spacer()
                        Slider(value: $threshold)
                            .frame(width: 150)
                            .onChange(of: threshold) { oldValue, newValue in
                                whisperState.silentLeveldB = Float(-70 + newValue * 70)
                            }
                    }
                    Button(action: {
                        Task {
                            let success = await whisperState.toggleRecord()
                            showingAlert = !success
                        }
                    }, label: {
                        if whisperState.isRecording {
                            Image(systemName: "stop")
                                .font(.largeTitle)
                        }
                        else {
                            Image(systemName: "waveform.circle.fill")
                                .font(.largeTitle)
                                .tint(.red)
                        }
                    })
                    .anchorPreference(
                        key: BoundsPreferenceKey.self,
                        value: .bounds
                    ) { spotlighting ? [$0] : [] }
                }
            }
            else {
                HStack {
                    Button(action: {
                        showConfig.toggle()
                    }, label: {
                        Image(systemName: "gear")
                            .font(.largeTitle)
                    })
                    Text("Model is loading. Please wait")
                    ForEach(0..<counter%5, id: \.self) { _ in
                        Text(verbatim: ".")
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .overlayPreferenceValue(BoundsPreferenceKey.self) { value in
            GeometryReader { proxy in
                if let preference = value.first {
                    let rect = proxy[preference]
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .reverseMask(alignment: .topLeading) {
                            Circle()
                                .frame(width: rect.width + 100, height: rect.height + 100)
                                .offset(x: rect.minX - 50, y: rect.minY - 50)
                        }
                }
            }
        }
        .onAppear {
            threshold = (silentLeveldB + 70) / 70
            whisperState.bufferSec = bufferSec
            whisperState.silentLeveldB = Float(silentLeveldB)
            whisperState.contCount = contCount
            whisperState.fixLanguage = language
            whisperState.languageCutoff = languageCutoff
        }
        .onChange(of: whisperState.isModelLoaded) { oldValue, newValue in
            if newValue {
                Task.detached { @MainActor in
                    whisperState.messageLog = [
                        String(localized: "Ready to start."),
                        String(localized: "LogPress to export log."),
                    ]
                    if tutorial == 0 {
                        spotlighting = true
                        tutorial += 1
                    }
                }
            }
        }
        .onChange(of: scenePhase) { oldValue, newValue in
            if newValue == .background, whisperState.isRecording {
                Task {
                    await whisperState.toggleRecord()
                }
            }
        }
        .onReceive(timer) { t in
            counter += 1
            if spotlighting {
                withAnimation(.easeInOut.delay(1)) {
                    spotlighting = false
                }
            }
            volLeveldB = Double(whisperState.volLeveldB)
            silentLeveldB = Double(whisperState.silentLeveldB)
            active = whisperState.active
            waitTime = whisperState.waitTime
            callCount = whisperState.callCount
            detectLanguage = whisperState.language
            if whisperState.isRecording {
                if active {
                    stateLog = String(localized: "[listening...]")
                }
                else if callCount > 0 {
                    stateLog = String(localized: "[converting...]")
                }
                else {
                    stateLog = String(localized: "[waiting to speak...]")
                }
            }
            else {
                stateLog = ""
            }
        }
        .fullScreenCover(isPresented: $showEdit) {
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
                        showEdit = false
                    }
                }
                .padding()
                TextEditor(text: $resultText)
            }
            .onAppear {
                resultText = whisperState.messageLog.joined(separator: "\n")
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
        .sheet(isPresented: $showConfig, onDismiss: {
            whisperState.bufferSec = bufferSec
            whisperState.contCount = contCount
            whisperState.fixLanguage = language
            whisperState.languageCutoff = languageCutoff
        }) {
            VStack {
                HStack {
                    Spacer()
                    Button("Done") {
                        showConfig = false
                    }
                }
                Spacer()
                HStack {
                    Text("Buffer length")
                    Picker("Buffer length", selection: $bufferSec) {
                        ForEach(3..<30) { sec in
                            Text("\(sec) sec").tag(sec)
                        }
                    }
                }
                HStack {
                    Text("Silence split")
                    Picker("Silence split", selection: $contCount) {
                        ForEach(1..<15) { count in
                            Text("\(Float(count) * 0.2, format: .number.precision(.fractionLength(1))) sec").tag(count)
                        }
                    }
                }
                HStack {
                    Text("Set language")
                    Picker("Set language", selection: $language) {
                        ForEach(whisperState.languageList, id: \.self) { lang in
                            Text(String(localized: String.LocalizationValue(lang))).tag(lang)
                        }
                    }
                }
                HStack {
                    Text("Language detection cutoff")
                    Slider(value: $languageCutoff)
                    Text(verbatim: "\(languageCutoff.formatted(.number.precision(.fractionLength(2))))")
                }
                .disabled(language != "auto")
                Spacer()
                Button(action: {
                    showConfig = false
                    dismiss()
                }, label: {
                    Text("Change model")
                })
                Spacer()
            }
            .padding()
        }
        .alert(isPresented: $showingAlert) {
            Alert(title: Text("Microphone permission error"),
                  message: Text("Failed to get permission for microphone to recode voice."))
        }
    }
}

#Preview {
    ContentView(whisperState: WhisperState(model_size: ""))
}
