//
//  SpeechRecognitionService.swift
//  SilicIA
//
//  Created by OpenCode on 19/04/2026.
//

import Combine
import Foundation

#if canImport(AVFoundation) && canImport(Speech)
import AVFoundation
import Speech

@MainActor
final class SpeechRecognitionService: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onTextUpdate: ((String) -> Void)?
    private var onStop: (() -> Void)?
    private var baseText = ""

    func toggle(
        initialText: String,
        locale: Locale = .current,
        onTextUpdate: @escaping (String) -> Void,
        onStop: (() -> Void)? = nil
    ) {
        if isListening {
            stop()
        } else {
            start(initialText: initialText, locale: locale, onTextUpdate: onTextUpdate, onStop: onStop)
        }
    }

    func start(
        initialText: String,
        locale: Locale = .current,
        onTextUpdate: @escaping (String) -> Void,
        onStop: (() -> Void)? = nil
    ) {
        Task {
            await startInternal(initialText: initialText, locale: locale, onTextUpdate: onTextUpdate, onStop: onStop)
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        let shouldNotifyStop = isListening
        isListening = false

        if shouldNotifyStop {
            onStop?()
        }
        onTextUpdate = nil
        onStop = nil
    }

    private func startInternal(
        initialText: String,
        locale: Locale,
        onTextUpdate: @escaping (String) -> Void,
        onStop: (() -> Void)?
    ) async {
        stop()
        errorMessage = nil

        let speechAuthorized = await requestSpeechAuthorization()
        guard speechAuthorized else {
            errorMessage = "Speech recognition permission was denied."
            return
        }

        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard microphoneAuthorized else {
            errorMessage = "Microphone permission was denied."
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            errorMessage = "Speech recognizer is currently unavailable."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        recognitionRequest = request

        self.onTextUpdate = onTextUpdate
        self.onStop = onStop
        baseText = initialText.trimmingCharacters(in: .whitespacesAndNewlines)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
        }

        do {
            #if canImport(UIKit)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
        } catch {
            errorMessage = "Unable to start audio capture: \(error.localizedDescription)"
            stop()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            Task { @MainActor in
                if let result {
                    let spoken = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let combined = Self.combinedText(base: self.baseText, spoken: spoken)
                    self.onTextUpdate?(combined)

                    if result.isFinal {
                        self.stop()
                    }
                }

                if let error {
                    self.errorMessage = error.localizedDescription
                    self.stop()
                }
            }
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        #if os(macOS)
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }

    private static func combinedText(base: String, spoken: String) -> String {
        guard !spoken.isEmpty else { return base }
        guard !base.isEmpty else { return spoken }
        return "\(base) \(spoken)"
    }
}
#else
@MainActor
final class SpeechRecognitionService: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String? = "Speech recognition is unavailable on this platform."

    func toggle(
        initialText: String,
        locale: Locale = .current,
        onTextUpdate: @escaping (String) -> Void,
        onStop: (() -> Void)? = nil
    ) {
        _ = initialText
        _ = locale
        _ = onTextUpdate
        onStop?()
    }

    func start(
        initialText: String,
        locale: Locale = .current,
        onTextUpdate: @escaping (String) -> Void,
        onStop: (() -> Void)? = nil
    ) {
        _ = initialText
        _ = locale
        _ = onTextUpdate
        onStop?()
    }

    func stop() {
        isListening = false
    }
}
#endif
