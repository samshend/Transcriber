import AVFoundation
import CoreAudio
import Foundation

struct TapError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Captures everything the Mac plays (calls, videos, …) using a Core Audio process tap
/// (macOS 14.2+). Requires the "System Audio Recording" permission, which macOS asks
/// for on first use. Audio is written to an AAC file; mixing with the mic happens later.
final class SystemAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var _paused = false
    private var _lastBufferAt = Date()
    private var _lastAudibleAt = Date()
    private var _sampleRate: Double = 0
    private(set) var framesWritten: Int64 = 0

    /// Below this RMS the far side is treated as silent (~ -50 dBFS). Room tone and an idle
    /// call sit under it; speech sits well above.
    private static let audibleFloor: Float = 0.003

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }

    /// How much audio actually landed in the file — compared against the mic track on stop
    /// to catch a capture that died mid-recording.
    var secondsWritten: Double {
        lock.lock(); defer { lock.unlock() }
        return _sampleRate > 0 ? Double(framesWritten) / _sampleRate : 0
    }

    var secondsSinceLastBuffer: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastBufferAt)
    }

    /// How long the captured audio has been below the audible floor — the signal the meeting
    /// "silence" detector uses to decide a call has ended.
    var secondsSinceAudible: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastAudibleAt)
    }

    func start(writingTo url: URL) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError(message: "could not create system audio tap (error \(status)); check System Settings → Privacy & Security → Screen & System Audio Recording")
        }
        tapID = newTapID

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &streamDescription) else {
            cleanUpCoreAudio()
            throw TapError(message: "could not read tap format (error \(status))")
        }
        tapFormat = format

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Transcriber System Audio",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            cleanUpCoreAudio()
            throw TapError(message: "could not create capture device (error \(status))")
        }
        aggregateID = newAggregateID

        let channels = min(format.channelCount, 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let newFile = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            file = newFile
            lock.lock()
            _sampleRate = newFile.processingFormat.sampleRate
            _lastBufferAt = Date()
            lock.unlock()
            if format != newFile.processingFormat {
                converter = AVAudioConverter(from: format, to: newFile.processingFormat)
            }
        } catch {
            cleanUpCoreAudio()
            throw TapError(message: "could not create system audio file: \(error.localizedDescription)")
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let ioProcID else {
            cleanUpCoreAudio()
            file = nil
            throw TapError(message: "could not attach to capture device (error \(status))")
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanUpCoreAudio()
            file = nil
            throw TapError(message: "could not start system audio capture (error \(status))")
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        cleanUpCoreAudio()
        lock.lock()
        file = nil
        lock.unlock()
    }

    private func cleanUpCoreAudio() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        lock.lock()
        defer { lock.unlock() }
        _lastBufferAt = Date()
        guard let file, !_paused, let tapFormat else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil),
              buffer.frameLength > 0 else { return }

        let toWrite: AVAudioPCMBuffer
        if let converter {
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: buffer.frameLength
            ) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }
            toWrite = converted
        } else {
            toWrite = buffer
        }

        if rms(of: toWrite) >= Self.audibleFloor {
            _lastAudibleAt = Date()
        }

        if (try? file.write(from: toWrite)) != nil {
            framesWritten += Int64(toWrite.frameLength)
        }
    }

    /// Root-mean-square level of the first channel (0…~1). Cheap enough for the audio thread.
    private func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { let s = channel[i]; sum += s * s }
        return (sum / Float(count)).squareRoot()
    }
}
