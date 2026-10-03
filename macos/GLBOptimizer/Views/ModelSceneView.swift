import AppKit
import SceneKit
import SwiftUI

struct ModelSceneView: NSViewRepresentable {
    var preview: PreviewScene?

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(white: 0.16, alpha: 1)
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.shown !== preview?.scene else { return }
        context.coordinator.shown = preview?.scene
        guard let preview else {
            view.scene = nil
            return
        }
        let scene = preview.scene
        if scene.lightingEnvironment.contents == nil {
            scene.lightingEnvironment.contents = Self.environment
            scene.lightingEnvironment.intensity = 1.4
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 900
            sun.eulerAngles = SCNVector3(-0.9, 0.6, 0)
            scene.rootNode.addChildNode(sun)
        }

        let radius = preview.radius
        let center = SCNVector3(preview.center)
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 100
        camera.wantsHDR = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let distance = radius / sin(Float(camera.fieldOfView) * .pi / 360) * 1.05
        cameraNode.simdPosition = preview.center + SIMD3(0.35, 0.25, 1).normalizedVector * distance
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode
        view.defaultCameraController.target = center
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: SCNScene?
    }

    /// Soft studio gradient used as image-based lighting so PBR metals do not render black.
    private static let environment: NSImage = {
        let size = NSSize(width: 512, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [
            NSColor(white: 0.95, alpha: 1),
            NSColor(white: 0.62, alpha: 1),
            NSColor(white: 0.22, alpha: 1),
        ])?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }()
}

private extension SIMD3 where Scalar == Float {
    var normalizedVector: SIMD3<Float> { self / max(sqrt((self * self).sum()), 1e-6) }
}
