//
//  StatusSound.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 22/10/26.
//
//  Short tones for task status changes, generated in code (no audio files).
//  Follows the silent switch. Uses the same `celebrationSound` UserDefaults key as the done chime.
//  Replaces MissedSound.swift. New file, not in zip.
//
//    .missed       soft double knock on one pitch, a quiet "heads up"
//    .rescheduled  falling two-note chime (B-flat to F), "it has been moved"

import AVFoundation

enum StatusSound {

    enum Tone { case missed, rescheduled }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "celebrationSound") as? Bool ?? true
    }

    /// Plays off the main thread so audio setup never blocks the UI.
    static func play(_ tone: Tone) {
        guard isEnabled else { return }
        queue.async {
            _ = configureSession
            let data = cache[tone] ?? makeWav(for: tone)
            cache[tone] = data
            do {
                let p = try AVAudioPlayer(data: data)
                p.volume = 1.0
                p.prepareToPlay()
                p.play()
                player = p
            } catch {
                #if DEBUG
                print("StatusSound failed:", error)
                #endif
            }
        }
    }

    // MARK: Playback

    private static var player: AVAudioPlayer?
    private static var cache: [Tone: Data] = [:]
    private static let queue = DispatchQueue(label: "autoday.statussound", qos: .userInitiated)

    /// Set once. `.ambient` respects the silent switch and mixes with the user's music.
    private static let configureSession: Void = {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }()

    // MARK: Synthesis

    private struct Note {
        let freq: Double
        let start: Double
        let length: Double
    }

    private struct Recipe {
        let notes: [Note]
        let total: Double
        let overtone: Double    // level of the 2nd harmonic
        let decay: Double       // higher = shorter, more percussive
    }

    private static func recipe(for tone: Tone) -> Recipe {
        switch tone {
        case .missed:
            return Recipe(notes: [Note(freq: 329.63, start: 0.00, length: 0.14),
                                  Note(freq: 329.63, start: 0.17, length: 0.20)],
                          total: 0.45, overtone: 0.12, decay: 14)
        case .rescheduled:
            return Recipe(notes: [Note(freq: 466.16, start: 0.00, length: 0.24),
                                  Note(freq: 349.23, start: 0.16, length: 0.38)],
                          total: 0.60, overtone: 0.25, decay: 8)
        }
    }

    private static func makeWav(for tone: Tone) -> Data {
        let r    = recipe(for: tone)
        let rate = 44_100.0
        let n    = Int(r.total * rate)
        var mix  = [Double](repeating: 0, count: n)

        for note in r.notes {
            let s0  = Int(note.start * rate)
            let len = Int(note.length * rate)
            for i in 0..<len where s0 + i < n {
                let t       = Double(i) / rate
                let attack  = min(t / 0.005, 1)
                let release = min(1, (note.length - t) / 0.04)
                let env     = attack * release * exp(-t * r.decay)
                let wave    = sin(2 * .pi * note.freq * t)
                            + r.overtone * sin(2 * .pi * note.freq * 2 * t)
                mix[s0 + i] += wave * env * 0.35
            }
        }

        let samples = mix.map { Int16(max(-1, min(1, $0)) * Double(Int16.max)) }

        var data = Data()
        func append32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        let byteCount = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!)
        append32(36 + byteCount)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append32(16)                      // PCM chunk size
        append16(1)                       // PCM
        append16(1)                       // mono
        append32(UInt32(rate))
        append32(UInt32(rate) * 2)        // byte rate
        append16(2)                       // block align
        append16(16)                      // bits per sample
        data.append("data".data(using: .ascii)!)
        append32(byteCount)
        for s in samples { append16(UInt16(bitPattern: s)) }
        return data
    }
}
