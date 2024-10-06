//
//  ContentView.swift
//  whisper
//
//  Created by rei9 on 2024/04/17.
//

import SwiftUI
import AVFoundation

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
    @EnvironmentObject var userData: StateHolder
    @Binding var whisperState: WhisperState
    @State var showingAlert = false
    @State var importerPresented = false

    @AppStorage("silentLevel") var silentLeveldB = -20.0
    @AppStorage("gainTargetLevel") var gainTargetdB = 0.0
    @AppStorage("soundValueThold") var volDevThreshold = 0.75
    @AppStorage("tutorial") var tutorial = 0
    @AppStorage("colorP") var colorP = true
    @AppStorage("bufferSec") var bufferSec = 10
    @AppStorage("contCount") var contCount = 15
    @AppStorage("language") var language = "auto"
    @AppStorage("languageCutoff") var languageCutoff = 0.3
    @AppStorage("showTimestamp") var showTimestamp = true

    let timer = Timer.publish(every: 0.2, on: .current, in: .common).autoconnect()
    @State var volLeveldB = -40.0
    @State var volSpec = 0.0
    @State var active = false
    @State var waitTime = 0.0
    @State var callCount = 0
    @State var detectLanguage = ""
    @State var stateLog = ""
    @State var stateColor = Color.clear
    @State var spotlighting = false
    @State var counter = 0
    @State var logLines = 0
    var backColor: Color? {
        if colorP {
            if colorScheme == .light {
                return Color(white: 0.75)
            }
        }
        return nil
    }
    var zeroLineColor: Color {
        colorScheme == .light ? .black : .white
    }
    
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    
    @State var tformatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter
    }()
    
    struct VLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.size.width * 40 / 50, y: 0))
            path.addLine(to: CGPoint(x: rect.size.width * 40 / 50, y: rect.size.height))
            return path
        }
    }

    struct VolumeView : View {
        var volume: Double
        var active: Bool

        init(volume: Double, active: Bool){
            self.volume = max(-40, volume)
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
                    .background(LeftPart(pct: CGFloat(volume + 40)/50).fill(active ? .red : .gray))
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
        var value: Double

        init(value: Double){
            self.value = min(max(0, value), 2)
        }

        var body: some View {
            ZStack {
                HStack {
                    Text("\(value, format: .number.precision(.fractionLength(2)))")
                        .font(.subheadline.monospacedDigit())
                    Rectangle()
                        .foregroundStyle(Color.clear)
                        .frame(height: 5)
                        .background(LeftPart(pct: CGFloat(value/2)).fill(.green))
                }
                HStack {
                    Spacer()
                    Text("Threshold")
                        .font(.subheadline)
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

    struct SpecView : View {
        var value: Double
        var active: Bool

        init(value: Double, active: Bool){
            self.value = min(max(0, value), 2)
            self.active = active
        }

        var body: some View {
            ZStack {
                HStack {
                    Text("\(value, format: .number.precision(.fractionLength(2)))")
                        .font(.subheadline.monospacedDigit())
                    Rectangle()
                        .foregroundStyle(Color.clear)
                        .frame(height: 5)
                        .background(LeftPart(pct: CGFloat(value/2)).fill(active ? .yellow : .gray))
                }
                HStack {
                    Spacer()
                    Text("Sound socre")
                        .font(.subheadline)
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
    
    var indicator: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Spacer()
                    Text("Gain")
                    Text(whisperState.currentGain, format: .number.precision(.fractionLength(2)))
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
                VolumeView(volume: volLeveldB, active: active)
                Spacer().frame(height: 45)
            }
            SpecView(value: volSpec, active: active)
            ThresholdView(value: volDevThreshold)
        }
    }
    
    var body: some View {
        VStack {
            if whisperState.isModelLoaded {
                ZStack {
                    HStack {
                        if let tstr = tformatter.string(from: TimeInterval(Double(whisperState.timeCount) / 16000)) {
                            Text(tstr)
                                .font(.body.monospacedDigit())
                        }
                        if !whisperState.isRecording {
                            Button(action: {
                                Task.detached { @MainActor in
                                    whisperState.clearLog()
                                }
                            }, label: {
                                Image(systemName: "trash")
                                    .tint(.red)
                            })
                        }
                        Spacer()
                    }
                    HStack {
                        if callCount > 0 {
                            Text("processing")
                                .font(.subheadline.monospacedDigit())
                        }
                        if waitTime > 0 {
                            Text("\(waitTime, format: .number.precision(.fractionLength(2))) sec wait")
                                .font(.subheadline.monospacedDigit())
                        }
                        Text(String(localized: String.LocalizationValue(detectLanguage)))
                    }
                    .foregroundStyle(callCount == 0 ? .primary: Color.blue)
                }
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(0..<whisperState.messageLog.count, id: \.self) { i in
                            if colorP {
                                HStack(alignment: .top) {
                                    if showTimestamp, whisperState.messageTiming.count > i, let tstr = tformatter.string(from: TimeInterval(whisperState.messageTiming[i])) {
                                        Text(tstr)
                                            .font(.body.monospacedDigit())
                                    }
                                    Text(whisperState.messageLog[i])
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .onTapGesture{}
                                        .onLongPressGesture(minimumDuration: 0.5) {
                                            if whisperState.isRecording {
                                                return
                                            }
                                            let resultText = whisperState.messageLog.map({ String($0.characters) }).joined(separator: "\n")
                                            userData.presentedPage.append(.edit(text: resultText))
                                        }
                                }
                            }
                            else {
                                HStack(alignment: .top) {
                                    if showTimestamp, whisperState.messageTiming.count > i, let tstr = tformatter.string(from: TimeInterval(whisperState.messageTiming[i])) {
                                        Text(tstr)
                                            .font(.body.monospacedDigit())
                                    }
                                    Text(String(whisperState.messageLog[i].characters))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .onTapGesture{}
                                        .onLongPressGesture(minimumDuration: 0.5) {
                                            if whisperState.isRecording {
                                                return
                                            }
                                            let resultText = whisperState.messageLog.map({ String($0.characters) }).joined(separator: "\n")
                                            userData.presentedPage.append(.edit(text: resultText))
                                        }
                                }
                            }
                        }
                        Text(stateLog)
                            .foregroundStyle(stateColor)
                            .frame(maxWidth: .infinity, alignment: .leading).id(-1)
                    }
                }
                .onChange(of: whisperState.messageLog.count) { oldValue, newValue in
                    reader.scrollTo(-1)
                }
            }
            if whisperState.isModelLoaded {
                ZStack {
                    indicator
                    VLine()
                        .stroke()
                        .foregroundStyle(zeroLineColor)
                        .frame(height: 15)
                }
                Spacer()
                ZStack {
                    HStack {
                        Button(action: {
                            userData.presentedPage.append(.config)
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
                    }
                    Button(action: {
                        Task.detached {
                            let success = await whisperState.toggleRecord()
                            Task.detached { @MainActor in
                                showingAlert = !success
                            }
                        }
                    }, label: {
                        if whisperState.isRecording {
                            Image(systemName: "stop")
                                .font(.largeTitle)
                        }
                        else {
                            Image(systemName: "waveform.badge.mic")
                                .font(.largeTitle)
                                .tint(.red)
                        }
                    })
                    .disabled(whisperState.isProcessing)
                    .anchorPreference(
                        key: BoundsPreferenceKey.self,
                        value: .bounds
                    ) { spotlighting ? [$0] : [] }
                }
            }
            else {
                HStack {
                    Text("Model is loading. Please wait")
                    ForEach(0..<counter%5, id: \.self) { _ in
                        Text(verbatim: ".")
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(backColor)
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
            whisperState.bufferSec = bufferSec
            whisperState.silentLeveldB = Float(silentLeveldB)
            whisperState.contCount = contCount
            whisperState.fixLanguage = language
            whisperState.languageCutoff = languageCutoff
            whisperState.volDevThreshold = Float(volDevThreshold)
            whisperState.gainTargetdB = Float(gainTargetdB)
        }
        .onChange(of: whisperState.isModelLoaded) { oldValue, newValue in
            if newValue {
                Task.detached { @MainActor in
                    whisperState.messageLog = [
                        AttributedString(String(localized: "Ready to start.")),
                        AttributedString(String(localized: "LogPress to export log.")),
                    ]
                    if tutorial == 0 {
                        spotlighting = true
                        tutorial += 1
                    }
                }
            }
        }
        .onReceive(timer) { t in
            if showingAlert { return }
            counter += 1
            if spotlighting {
                withAnimation(.easeInOut.delay(1)) {
                    spotlighting = false
                }
            }
            volLeveldB = Double(whisperState.volLeveldB)
            silentLeveldB = Double(whisperState.silentLeveldB)
            volSpec = Double(whisperState.volDev)
            active = whisperState.active
            waitTime = whisperState.waitTime
            callCount = Int(whisperState.callCount)
            detectLanguage = whisperState.language
            if whisperState.isRecording {
                if active {
                    stateLog = String(localized: "[listening...]")
                    stateColor = .red
                }
                else if callCount > 0 {
                    stateLog = String(localized: "[converting...]")
                    stateColor = .blue
                }
                else {
                    stateLog = String(localized: "[waiting to speak...]")
                    stateColor = .purple
                }
            }
            else {
                stateLog = ""
                stateColor = .clear
            }
        }
        .alert(isPresented: $showingAlert) {
            Alert(title: Text("Microphone permission error"),
                  message: Text("Failed to get permission for microphone to recode voice."))
        }
    }
}

#Preview {
    @Previewable @State var whisperState = WhisperState(model_size: "tiny")
    ContentView(whisperState: $whisperState)
}
