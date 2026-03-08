//
//  CameraPreviewView.swift
//  TrapjawApp
//
//  UIViewRepresentable wrapper around AVCaptureVideoPreviewLayer
//  for embedding a live camera preview in SwiftUI.
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Session is already set; layout handled by PreviewUIView
    }
}

/// A UIView backed by AVCaptureVideoPreviewLayer for correct auto-layout sizing.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
