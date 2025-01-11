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
    @State private var showingAlert = false
    @State private var importerPresented = false
    @State private var isDragging = false
    @State private var autoScroll = true
    @State private var scrollOffset = 0 {
        didSet {
            if scrollOffset < 0 {
                scrollOffset = 0
            }
            if scrollOffset > lineCount {
                scrollOffset = lineCount
            }
            if scrollOffset > scrollMaxOffset {
                scrollOffset = scrollMaxOffset
            }
        }
    }
    @State private var scrollMaxOffset = 0 {
        didSet {
            if scrollMaxOffset < 0 {
                scrollMaxOffset = 0
            }
            if scrollMaxOffset > lineCount {
                scrollMaxOffset = lineCount
            }
            if scrollOffset > scrollMaxOffset {
                scrollOffset = scrollMaxOffset
            }
        }
    }
    @State private var scrollPosition = ScrollPosition()
    @State private var logViewOffset: CGFloat = 0.0
    @State private var visibleIndex: Set<Int> = []
    @State private var scrollHeightFactor: CGFloat = 0.0
    @State private var lineCount = 0 {
        didSet {
            if oldValue > lineCount {
                scrollOffset = lineCount
            }
        }
    }
    @State private var prevLineCount = 0

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
    @State var isRecording = false
    @State var transrate = false
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

    func clearLog() {
        whisperState.clearLog()
        lineCount = 0
        Task {
            try await Task.sleep(for: .milliseconds(300))
            scrollToBottom()
            autoScroll = true
        }
    }

    var headerView: some View {
        ZStack {
            HStack {
                if let tstr = tformatter.string(from: TimeInterval(Double(whisperState.timeCount) / 16000)) {
                    Text(tstr)
                        .font(.body.monospacedDigit())
                }
                if !isRecording {
                    Button(action: {
                        clearLog()
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
            HStack {
                Spacer()
                if autoScroll {
                    Image(systemName: "arrow.down.to.line")
                }
                else {
                    Image(systemName: "play.slash.fill")
                }
            }
        }
        .onReceive(timer) { t in
            if isRecording {
                waitTime = whisperState.waitTime
                callCount = Int(whisperState.callCount)
                detectLanguage = whisperState.language
            }
            else if callCount > 0 {
                waitTime = 0
                callCount = 0
                detectLanguage = ""
            }
        }
    }

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
                        .frame(width: 80, alignment: .trailing)
                }
                VolumeView(volume: volLeveldB, active: active)
                Spacer().frame(height: 45)
            }
            SpecView(value: volSpec, active: active)
            ThresholdView(value: volDevThreshold)
        }
    }

    func colorText(str: String, prob: [Double]) -> AttributedString {
        var result = AttributedString(stringLiteral: str)
        for p in prob.enumerated() {
            guard p.offset < result.characters.count else { break }
            if colorScheme == .light {
                result[result.index(result.startIndex, offsetByCharacters: p.offset)..<result.index(result.startIndex, offsetByCharacters: p.offset+1)].backgroundColor = Color(red: 1, green: 0, blue: 0, opacity: 1 - p.element)
            }
            else {
                result[result.index(result.startIndex, offsetByCharacters: p.offset)..<result.index(result.startIndex, offsetByCharacters: p.offset+1)].foregroundColor = Color(red: 1, green: p.element, blue: p.element)
            }
        }
        return result
    }

    struct LogLineView: View {
        let i: Int
        let parent: ContentView

        @ViewBuilder
        var timeStr: some View {
            if parent.showTimestamp, let t = parent.whisperState.messageLog[i].timing, let tstr = parent.tformatter.string(from: TimeInterval(t)) {
                Text(tstr)
                    .font(.body.monospacedDigit())
            }
        }

        @ViewBuilder
        var logStr: some View {
            if parent.colorP {
                Text(parent.colorText(str: parent.whisperState.messageLog[i].message, prob: parent.whisperState.messageLog[i].prob))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            else {
                Text(parent.whisperState.messageLog[i].message)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @ViewBuilder
        var mainContent: some View {
            if i >= 0, i < min(parent.whisperState.messageLog.count, parent.lineCount) {
                HStack(alignment: .top) {
                    timeStr
                    logStr
                }
            }
            else if i == min(parent.whisperState.messageLog.count, parent.lineCount) {
                Text(parent.stateLog)
                    .foregroundStyle(parent.stateColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        var body: some View {
            mainContent
        }
    }

    struct RootLineView: View, Identifiable {
        let id: Int
        let parent: ContentView

        var body: some View {
            LogLineView(i: id + parent.scrollOffset, parent: parent)
        }
    }

    var indicatorView: some View {
        VStack {
            if isRecording {
                ZStack {
                    indicator
                    VLine()
                        .stroke()
                        .foregroundStyle(zeroLineColor)
                        .frame(height: 15)
                }
                .onAppear {
                    if autoScroll {
                        Task {
                            try await Task.sleep(for: .milliseconds(300))
                            scrollToBottom()
                            autoScroll = true
                        }
                    }
                }
            }
            ZStack {
                HStack {
                    Button(action: {
                        userData.presentedPage.append(.config)
                    }, label: {
                        Image(systemName: "gear")
                            .font(.largeTitle)
                    })
                    .disabled(isRecording)
                    Button(action: {
                        transrate.toggle()
                        whisperState.transrate = transrate
                    }, label: {
                        if transrate {
                            Text("in English")
                        }
                        else {
                            Text("transcribe")
                        }
                    })
                    .disabled(isRecording)
                    Spacer()
                }

                if !whisperState.isPlaying || !isRecording {
                    Button(action: {
                        Task.detached {
                            let success = await whisperState.toggleRecord()
                            if await whisperState.isRecording {
                                Task { @MainActor [self] in
                                    Task {
                                        try await Task.sleep(for: .milliseconds(300))
                                        scrollToBottom()
                                        autoScroll = true
                                    }
                                }
                            }
                            Task.detached { @MainActor in
                                showingAlert = !success
                            }
                        }
                    }, label: {
                        if isRecording {
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

                HStack {
                    Spacer()
                    Text(whisperState.model_size)
                    if whisperState.isPlaying || !isRecording {
                        Button(action: {
                            if isRecording {
                                Task.detached {
                                    await whisperState.togglePlay(file: URL(fileURLWithPath: ""))
                                }
                            }
                            else {
                                importerPresented = true
                            }
                        }, label: {
                            if isRecording {
                                Image(systemName: "stop")
                                    .font(.largeTitle)
                            }
                            else {
                                Image(systemName: "play.circle")
                                    .font(.largeTitle)
                                    .tint(.green)
                            }
                        })
                        .disabled(whisperState.isProcessing)
                    }
                }
            }
        }
        .onReceive(timer) { t in
            if isRecording {
                volLeveldB = Double(whisperState.volLeveldB)
                silentLeveldB = Double(whisperState.silentLeveldB)
                volSpec = Double(whisperState.volDev)
                active = whisperState.active
            }
        }
    }

    struct loadingView: View {
        let timer = Timer.publish(every: 0.1, on: .current, in: .common).autoconnect()
        @State var counter = 0

        var body: some View {
            HStack {
                Text("Model is loading. Please wait")
                ForEach(0..<counter, id: \.self) { _ in
                    Text(verbatim: ".")
                }
                Spacer()
            }
            .onReceive(timer) { t in
                counter = (counter + 1) % 10
            }
        }
    }

    func scrollToBottom() {
        //print("scrollToBottom", visibleIndex, visibleIndex.count, scrollOffset, lineCount, scrollMaxOffset)

        scrollPosition.scrollTo(y: scrollHeightFactor)
        Task {
            scrollOffset = scrollMaxOffset
        }
    }

    var contentLogView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(0..<100) { i in
                    RootLineView(id: i, parent: self)
                        .onAppear {
                            //print("a", i)
                            visibleIndex.insert(i)
                        }
                        .onDisappear {
                            //print("d", i)
                            visibleIndex.remove(i)
                        }
                }
                ForEach(1..<50) { i in
                    Text("")
                        .onAppear {
                            //print("a", -i)
                            visibleIndex.insert(-i)
                        }
                        .onDisappear {
                            //print("d", -i)
                            visibleIndex.remove(-i)
                        }
                }
            }
        }
        .scrollDisabled(true)
        .defaultScrollAnchor(.top)
        .offset(CGSize(width: 0, height: logViewOffset))
        .clipped()
        .onChange(of: visibleIndex) { oldValue, newValue in
            scrollHeightFactor = min(10000, CGFloat((max(0, lineCount - visibleIndex.count(where: { $0 >= 0 }))) * 20))

            if oldValue.isEmpty {
                // pass
            }
            else if oldValue.contains(where: { $0 < -1}), scrollOffset == 0, oldValue.filter({ $0 >= 0 }).contains(where: { $0 == 0}), newValue.contains(where: { $0 < -1}), newValue.filter({ $0 >= 0 }).contains(where: { $0 == 0}) {
                scrollMaxOffset = 0
            }
            else if newValue.allSatisfy({ $0 < 0 }) {
                scrollOffset = scrollMaxOffset
            }
            else if autoScroll, !newValue.contains(where: { $0 < 0 }) {
                scrollMaxOffset = max(scrollMaxOffset, lineCount - newValue.count(where: { $0 >= 0 }) / 2)
                scrollToBottom()
            }
            else if oldValue.count(where: { $0 < 0 }) > 0, oldValue.count(where: { $0 < 0 }) < newValue.count(where: { $0 < 0 }) {
                let c1 = newValue.count(where: { $0 < 0 }) - oldValue.count(where: { $0 < 0 })
                scrollMaxOffset = max(0, min(scrollMaxOffset, min(scrollMaxOffset, scrollOffset) - c1 + 1))
            }
            else if !oldValue.contains(where: { $0 < 0 }), newValue.contains(where: { $0 < 0 }) {
                let c1 = oldValue.count(where: { $0 >= 0 }) - newValue.count(where: { $0 >= 0 })
                if c1 > 0 {
                    scrollMaxOffset = min(scrollMaxOffset, scrollOffset - c1 + 1)
                }
            }
        }
        .onChange(of: lineCount) { oldValue, newValue in
            prevLineCount = oldValue
            scrollMaxOffset = max(0, newValue - visibleIndex.count(where: { $0 >= 0 }) + 2)
            scrollHeightFactor = min(10000, CGFloat((max(0, newValue - visibleIndex.count(where: { $0 >= 0 }))) * 20))
            if autoScroll {
                scrollToBottom()
            }
        }
    }

    var scrollLogView: some View {
        GeometryReader { geometry in
            ScrollView {
                Rectangle()
                    .foregroundStyle(.clear)
                    .frame(height: geometry.size.height + scrollHeightFactor)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { wasScrollY, isScrollY in
                guard wasScrollY != isScrollY else { return }
                //print(scrollHeightFactor, wasScrollY, isScrollY)
                //print("scroll", "autoScroll:", autoScroll, whisperState.messageLog.count, lineCount, scrollOffset, scrollMaxOffset, visibleIndex)

                if !autoScroll, isScrollY > scrollHeightFactor {
                    autoScroll = true
                    return
                }
                if autoScroll, max(isScrollY, wasScrollY) < scrollHeightFactor, isScrollY < wasScrollY {
                    autoScroll = false
                    return
                }

                if isScrollY < 0 {
                    logViewOffset = -isScrollY
                    scrollOffset = 0
                    return
                }

                if isScrollY > scrollHeightFactor {
                    logViewOffset = scrollHeightFactor - isScrollY
                    scrollOffset = scrollMaxOffset
                    return
                }
                logViewOffset = 0

                let newValue = Int(isScrollY / max(1, scrollHeightFactor) * CGFloat(scrollMaxOffset + 1))
                scrollOffset = min(lineCount, min(scrollMaxOffset, newValue))

                //print("scroll2", "autoScroll:", autoScroll, whisperState.messageLog.count, lineCount, scrollOffset, scrollMaxOffset, visibleIndex)
            }
        }
    }

    func convert_srt(message: [WhisperState.MessageLog]) -> String {
        let format = Duration.TimeFormatStyle(pattern: .hourMinuteSecond(padHourToLength: 2, fractionalSecondsLength: 3))
        return message.enumerated().map({
            "\($0.offset + 1)\n" +
            Duration.milliseconds(($0.element.timing ?? 0) * 1000).formatted(format).replacingOccurrences(of: ".", with: ",") +
            " --> " +
            Duration.milliseconds((($0.element.timing ?? 0) + ($0.element.duration ?? 0)) * 1000).formatted(format).replacingOccurrences(of: ".", with: ",") +
            "\n" + $0.element.message + "\n"
        }).joined(separator: "\n")
    }
    
    var body: some View {
        VStack {
            if whisperState.isModelLoaded {
                headerView
            }
            ZStack {
                contentLogView
                scrollLogView
            }
            .onTapGesture{}
            .onLongPressGesture(minimumDuration: 0.5) {
                if isRecording {
                    return
                }
                let resultText = convert_srt(message: whisperState.messageLog)
                userData.presentedPage.append(.edit(text: resultText))
            }
            if whisperState.isModelLoaded {
                indicatorView
            }
            else {
                loadingView()
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
            whisperState.bufferSec = bufferSec
            whisperState.silentLeveldB = Float(silentLeveldB)
            whisperState.contCount = contCount
            whisperState.fixLanguage = language
            whisperState.languageCutoff = languageCutoff
            whisperState.volDevThreshold = Float(volDevThreshold)
            whisperState.gainTargetdB = Float(gainTargetdB)
            lineCount = whisperState.messageLog.count
        }
        .onChange(of: whisperState.isModelLoaded) { oldValue, newValue in
            if oldValue != newValue, newValue {
                whisperState.clearLog()
                whisperState.appendMessage(contentsOf: [
                    String(localized: "Ready to start."),
                    String(localized: "LogPress to export log."),
                ])
                if tutorial == 0 {
                    spotlighting = true
                    tutorial += 1
                }
                lineCount = whisperState.messageLog.count
                Task {
                    try await Task.sleep(for: .milliseconds(300))
                    scrollToBottom()
                    autoScroll = true
                }
            }
        }
        .onReceive(timer) { t in
            if showingAlert { return }
            if spotlighting {
                withAnimation(.easeInOut.delay(1)) {
                    spotlighting = false
                }
            }
            lineCount = whisperState.messageLog.count
            if whisperState.isRecording {
                isRecording = true
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
            else if isRecording {
                stateLog = ""
                stateColor = .clear
                isRecording = false
            }
        }
        .alert(isPresented: $showingAlert) {
            Alert(title: Text("Microphone permission error"),
                  message: Text("Failed to get permission for microphone to recode voice."))
        }
        .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.movie, .audio]) { result in
            switch result {
            case .success(let url):
                print(url)
                Task.detached {
                    await whisperState.togglePlay(file: url)
                }
                Task {
                    try await Task.sleep(for: .milliseconds(300))
                    scrollToBottom()
                    autoScroll = true
                }
            case .failure:
                print("failure")
            }
        }
        .onDrop(of: [.item], isTargeted: $isDragging) { providers in
            let validProviders: [NSItemProvider] = providers.filter { $0.hasRepresentationConforming(toTypeIdentifier: UTType.movie.identifier, fileOptions: [.openInPlace]) || $0.hasRepresentationConforming(toTypeIdentifier: UTType.audio.identifier, fileOptions: [.openInPlace]) }
            if validProviders.isEmpty {
                return false
            }

            providers.forEach { provider in
                provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, isInPlace, error in
                    guard let url else { return }
                    print(url)
                    var error: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: url, error: &error) { url in
                        Task.detached {
                            await whisperState.togglePlay(file: url)
                        }
                    }
                }
                provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, isInPlace, error in
                    guard let url else { return }
                    print(url)
                    var error: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: url, error: &error) { url in
                        Task.detached {
                            await whisperState.togglePlay(file: url)
                        }
                    }
                }
            }
            return true
        }
    }
}

#Preview {
    @Previewable @State var whisperState = WhisperState(model_size: "tiny")
    ContentView(whisperState: $whisperState)
}
