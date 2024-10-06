//
//  ConfigView.swift
//  whisperapp
//
//  Created by rei9 on 2024/09/23.
//



import SwiftUI

struct ConfigView: View {
    @EnvironmentObject var userData: StateHolder
    @Binding var whisperState: WhisperState

    @AppStorage("bufferSec") var bufferSec = 10
    @AppStorage("contCount") var contCount = 15
    @AppStorage("language") var language = "auto"
    @AppStorage("noSpeechThold") var noSpeechThold = 0.6
    @AppStorage("languageCutoff") var languageCutoff = 0.3
    @AppStorage("colorP") var colorP = true
    @AppStorage("temperature") var temperature = 1.0
    @AppStorage("segmentProbThold") var segmentProbThold = 0.4
    @AppStorage("showTimestamp") var showTimestamp = true
    @AppStorage("silentLevel") var silentLeveldB = -20.0
    @AppStorage("gainTargetLevel") var gainTargetdB = 0.0
    @AppStorage("soundValueThold") var volDevThreshold = 0.75

    var body: some View {
            VStack {
                HStack {
                    Spacer()
                    Button("Done") {
                        userData.presentedPage.removeLast()
                    }
                }
                Spacer()
                Button(action: {
                    bufferSec = 10
                    contCount = 15
                    language = "auto"
                    noSpeechThold = 0.6
                    languageCutoff = 0.3
                    temperature = 1.0
                    segmentProbThold = 0.4
                    silentLeveldB = -20.0
                    gainTargetdB = 0.0
                    volDevThreshold = 0.75
                }, label: {
                    Text("Reset to default")
                })
                Group {
                    HStack {
                        Text("Buffer length")
                        Picker("Buffer length", selection: $bufferSec) {
                            ForEach(5..<26) { sec in
                                Text("\(sec) sec").tag(sec)
                            }
                        }
                    }
                    HStack {
                        Text("Silence split")
                        Picker("Silence split", selection: $contCount) {
                            ForEach(1..<40) { count in
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
                        Text("No speech threshold")
                        Slider(value: $noSpeechThold)
                        Text(verbatim: "\(noSpeechThold.formatted(.number.precision(.fractionLength(2))))")
                    }
                    HStack {
                        Text("Language detection cutoff")
                        Slider(value: $languageCutoff)
                        Text(verbatim: "\(languageCutoff.formatted(.number.precision(.fractionLength(2))))")
                    }
                    .disabled(language != "auto")
                    HStack {
                        Toggle(isOn: $colorP) {
                            Text("Color by probability")
                        }
                    }
                    HStack {
                        Text("Logit temperature")
                        Slider(value: $temperature, in: 0.0 ... 2.0)
                        Text(verbatim: "\(temperature.formatted(.number.precision(.fractionLength(3))))")
                    }
                    HStack {
                        Text("Segment probability cutoff")
                        Slider(value: $segmentProbThold)
                        Text(verbatim: "\(segmentProbThold.formatted(.number.precision(.fractionLength(2))))")
                    }
                }
                Group {
                    HStack {
                        Toggle(isOn: $showTimestamp) {
                            Text("Show timestamp")
                        }
                    }
                    HStack {
                        Text("Silence threshold")
                        Slider(value: $silentLeveldB, in: -40.0 ... 0.0)
                        Text(verbatim: "\(silentLeveldB.formatted(.number.precision(.fractionLength(1))))")
                    }
                    HStack {
                        Text("Gain target level")
                        Slider(value: $gainTargetdB, in: -40.0 ... 20.0)
                        Text(verbatim: "\(gainTargetdB.formatted(.number.precision(.fractionLength(1))))")
                    }
                    HStack {
                        Text("Sound value threshold")
                        Slider(value: $volDevThreshold, in: 0.0 ... 2.0)
                        Text(verbatim: "\(volDevThreshold.formatted(.number.precision(.fractionLength(3))))")
                    }
                }
                Spacer()
                Button(action: {
                    userData.presentedPage.removeAll()
                }, label: {
                    Text("Change model")
                })
                Spacer()
            }
            .padding()
            .onDisappear() {
                whisperState.bufferSec = bufferSec
                whisperState.contCount = contCount
                whisperState.fixLanguage = language
                whisperState.languageCutoff = languageCutoff
            }
        }
}

#Preview {
    @Previewable @State var whisperState = WhisperState(model_size: "tiny")
    ConfigView(whisperState: $whisperState)
}
