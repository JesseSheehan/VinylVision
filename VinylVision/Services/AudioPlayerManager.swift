//
//  AudioPlayerManager.swift
//  AlbumScanner
//

import Combine
import Foundation
import AVFoundation

class AudioPlayerManager: NSObject, ObservableObject {
    static let shared = AudioPlayerManager()
    
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    
    private override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    func play(url: String) {
        guard let url = URL(string: url) else { return }
        
        // Clean up existing player
        stop()
        
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        // Add observer for playback progress
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
            if let duration = self?.player?.currentItem?.duration.seconds, !duration.isNaN {
                self?.duration = duration
            }
        }
        
        // Add observer for end of playback
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        
        player?.play()
        isPlaying = true
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    func resume() {
        player?.play()
        isPlaying = true
    }
    
    func stop() {
        player?.pause()

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        player = nil
        NotificationCenter.default.removeObserver(self)
        
        isPlaying = false
        currentTime = 0
        duration = 0
    }
    
    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime)
    }
    
    @objc private func playerDidFinishPlaying() {
        isPlaying = false
        currentTime = 0
    }
    
    deinit {
        stop()
    }
}
