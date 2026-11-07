import AVFoundation
import AppKit
import SwiftUI

struct CameraPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> CameraPlayerSurface {
        let view = CameraPlayerSurface(frame: .zero)
        view.player = player
        return view
    }

    func updateNSView(_ nsView: CameraPlayerSurface, context: Context) {
        nsView.player = player
    }
}

final class CameraPlayerSurface: NSView {
    private var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            fatalError("CameraPlayerSurface must use an AVPlayerLayer")
        }
        return playerLayer
    }

    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}
