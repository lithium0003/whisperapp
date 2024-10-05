//
//  Recoder.swift
//  whisperapp
//
//  Created by rei9 on 2024/04/17.
//

import Foundation
import AVFoundation
import AudioToolbox

class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private(set) var recording = false
    private let captureSession = AVCaptureSession()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private var callback: (([Float])-> Void)?
    private var destDesc = {
        var desc = AudioStreamBasicDescription()
        desc.mChannelsPerFrame = 1
        desc.mSampleRate = 16000
        desc.mFormatID = kAudioFormatLinearPCM
        desc.mFormatFlags = kAudioFormatFlagsNativeFloatPacked
        desc.mBytesPerPacket = 4
        desc.mFramesPerPacket = 1
        desc.mBytesPerFrame = 4
        desc.mBitsPerChannel = 32
        return desc
    }()
    private var audioConverter: AudioConverterRef?
    private var outputBuffer: UnsafeMutableRawPointer?
    private let packetsPerLoop = 100
    private let audioConverterQueue = DispatchQueue(label: "audioQueue")
    private var outputBuf = [Float]()
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    func startRecording(callback: @escaping ([Float])-> Void) {
        if recording { return }
        
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
        
        do {
            // Wrap the audio device in a capture device input.
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            // If the input can be added, add it to the session.
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
            }
        } catch {
            // Configuration failed. Handle error.
            print(error)
            return
        }
        
        if captureSession.canAddOutput(audioDataOutput) {
            captureSession.addOutput(audioDataOutput)
        }
        self.callback = callback
        audioDataOutput.setSampleBufferDelegate(self, queue: audioConverterQueue)
        
        outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: packetsPerLoop * MemoryLayout<Float>.size, alignment: MemoryLayout<Float>.alignment)
        
        captureSession.startRunning()
        recording = true
    }
    
    func stopRecording() {
        guard recording else { return }
        captureSession.stopRunning()
        
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        audioConverterQueue.async { [weak self] in
            guard let self else { return }
            if audioConverter != nil {
                _ = AudioConverterDispose(audioConverter!)
                audioConverter = nil
            }
            if outputBuffer != nil {
                outputBuffer!.deallocate()
                outputBuffer = nil
            }
            recording = false
        }
    }
    
    class InputProcedure {
        let inputData: UnsafeMutableRawPointer?
        let desc: AudioStreamBasicDescription
        let dataLength: UInt32
        var isAvailable = true
        
        init(inputData: Data, desc: AudioStreamBasicDescription) {
            self.desc = desc
            self.dataLength = UInt32(inputData.count)
            self.inputData = UnsafeMutableRawPointer.allocate(byteCount: inputData.count, alignment: Int(desc.mBytesPerFrame))
            inputData.copyBytes(to: self.inputData!.bindMemory(to: UInt8.self, capacity: inputData.count), count: inputData.count)
        }
        
        deinit {
            inputData?.deallocate()
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let audioBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        guard let inputData = try? audioBuffer.dataBytes() else { return }
        
        guard var srcDesc = CMSampleBufferGetFormatDescription(sampleBuffer)?.audioStreamBasicDescription else { return }
        if audioConverter == nil {
//            print(srcDesc)
//            print(destDesc)
            AudioConverterNew(&srcDesc, &destDesc, &audioConverter)
        }
        guard let audioConverter else { return }
        
        var inproc = InputProcedure(inputData: inputData, desc: srcDesc)
        var numPackets = UInt32(packetsPerLoop)
        var dest = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(packetsPerLoop * MemoryLayout<Float>.size), mData: outputBuffer))
        
        let InputDataProc: AudioConverterComplexInputDataProc = { (inAudioConverter: AudioConverterRef, ioNumberDataPackets: UnsafeMutablePointer<UInt32>, ioData: UnsafeMutablePointer<AudioBufferList>, outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?, inUserData: UnsafeMutableRawPointer?) -> OSStatus in
            
            guard let selfPtr = inUserData?.assumingMemoryBound(to: InputProcedure.self).pointee else {
                return kAudioConverterErr_UnspecifiedError
            }
            if selfPtr.isAvailable {
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mNumberChannels = selfPtr.desc.mChannelsPerFrame
                ioData.pointee.mBuffers.mDataByteSize = selfPtr.dataLength
                ioData.pointee.mBuffers.mData = selfPtr.inputData
                let availCount = selfPtr.dataLength / selfPtr.desc.mBytesPerFrame
                let err = availCount >= ioNumberDataPackets.pointee ? errSecSuccess : errSecBufferTooSmall
                ioNumberDataPackets.pointee = availCount
                selfPtr.isAvailable = false
                return err
            }
            else {
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mNumberChannels = selfPtr.desc.mChannelsPerFrame
                ioData.pointee.mBuffers.mDataByteSize = 0
                ioData.pointee.mBuffers.mData = selfPtr.inputData
                ioNumberDataPackets.pointee = 0
                return errSecBufferTooSmall
            }
        }
        
        withUnsafeMutablePointer(to: &inproc) { p in
            while true {
                let ret = AudioConverterFillComplexBuffer(audioConverter, InputDataProc, p, &numPackets, &dest, nil)
                if ret != errSecSuccess {
                    break
                }
                
                let output = UnsafeRawBufferPointer(start: outputBuffer, count: Int(dest.mBuffers.mDataByteSize)).bindMemory(to: Float.self)
                let oCount = Int(numPackets)
                if oCount > 0 {
                    outputBuf.append(contentsOf: output[0..<oCount])
                }
                if oCount < numPackets {
                    break
                }
            }
        }
        if outputBuf.count > 160 * 20 {
            callback?(Array(outputBuf[0..<(160 * 20)]))
            outputBuf.removeFirst(160 * 20)
        }
    }
}
