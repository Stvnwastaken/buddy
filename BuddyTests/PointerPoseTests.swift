import CoreGraphics
import SwiftUI
import Testing
@testable import Buddy

@MainActor
struct PointerPoseTests {
    @Test func trianglePointsFromClearanceAtDisplayEdgesAndCorners() throws {
        let screen = CGRect(x: -1440, y: -300, width: 1440, height: 900)
        let targets: [(point: CGPoint, target: CGPoint, tip: CGPoint)] = [
            (CGPoint(x: -720, y: 570), CGPoint(x: 720, y: 30), CGPoint(x: 720, y: 48)),
            (CGPoint(x: -1440, y: 600), CGPoint(x: 0, y: 0), CGPoint(x: 12.727922, y: 12.727922)),
            (CGPoint(x: 0, y: 600), CGPoint(x: 1440, y: 0), CGPoint(x: 1427.272078, y: 12.727922)),
            (CGPoint(x: -1440, y: -300), CGPoint(x: 0, y: 900), CGPoint(x: 12.727922, y: 887.272078)),
            (CGPoint(x: 0, y: -300), CGPoint(x: 1440, y: 900), CGPoint(x: 1427.272078, y: 887.272078)),
            (CGPoint(x: -1440, y: 150), CGPoint(x: 0, y: 450), CGPoint(x: 12.727922, y: 462.727922)),
            (CGPoint(x: 0, y: 150), CGPoint(x: 1440, y: 450), CGPoint(x: 1427.272078, y: 462.727922)),
            (CGPoint(x: -720, y: -300), CGPoint(x: 720, y: 900), CGPoint(x: 720, y: 882)),
            (CGPoint(x: -720, y: -270), CGPoint(x: 720, y: 870), CGPoint(x: 720, y: 852)),
            (CGPoint(x: -1410, y: -270), CGPoint(x: 30, y: 870), CGPoint(x: 30, y: 852)),
            (CGPoint(x: -30, y: -270), CGPoint(x: 1410, y: 870), CGPoint(x: 1410, y: 852)),
            (CGPoint(x: -1439, y: -270), CGPoint(x: 1, y: 870), CGPoint(x: 13.727922, y: 857.272078)),
            (CGPoint(x: -1, y: -270), CGPoint(x: 1439, y: 870), CGPoint(x: 1426.272078, y: 857.272078))
        ]
        for expected in targets {
            let pose = PointerPose(pointingAt: expected.point, in: screen)
            #expect(pose.target == expected.target)
            let path = try renderedTriangle(for: pose)
            var vertices: [CGPoint] = []
            path.applyWithBlock { element in
                if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                    vertices.append(element.pointee.points[0])
                }
            }
            try #require(vertices.count == 3)
            let renderedTip = try #require(vertices.first)
            #expect(abs(renderedTip.x - expected.tip.x) < 0.001)
            #expect(abs(renderedTip.y - expected.tip.y) < 0.001)
            let toTarget = CGVector(dx: expected.target.x - renderedTip.x, dy: expected.target.y - renderedTip.y)
            #expect(abs(hypot(toTarget.dx, toTarget.dy) - 18) < 0.001)
            let base = CGPoint(x: (vertices[1].x + vertices[2].x) / 2, y: (vertices[1].y + vertices[2].y) / 2)
            let body = CGVector(dx: base.x - renderedTip.x, dy: base.y - renderedTip.y)
            #expect(abs(body.dx * toTarget.dy - body.dy * toTarget.dx) < 0.001)
            #expect(abs(body.dx * toTarget.dx + body.dy * toTarget.dy + 360) < 0.001)
            let bounds = path.boundingBoxOfPath
            #expect(bounds.minX >= -0.001 && bounds.maxX <= 1440.001)
            #expect(bounds.minY >= -0.001 && bounds.maxY <= 900.001)
        }
    }

    @Test func triangleLeavesMenuBarIconVisible() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let pose = PointerPose(pointingAt: CGPoint(x: 1340, y: 888), in: screen)
        #expect(pose.target == CGPoint(x: 1340, y: 12))
        let path = try renderedTriangle(for: pose)
        var tip: CGPoint?
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { tip = element.pointee.points[0] }
        }
        #expect(tip == CGPoint(x: 1340, y: 30))
        let icon = CGRect(x: 1328, y: 0, width: 24, height: 24)
        #expect(!path.boundingBoxOfPath.intersects(icon))
    }

    private func renderedTriangle(for pose: PointerPose) throws -> CGPath {
        var transform = CGAffineTransform(translationX: -PointerPose.size.width / 2, y: -PointerPose.size.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: pose.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: pose.position.x, y: pose.position.y))
        return try #require(Triangle().path(in: CGRect(origin: .zero, size: PointerPose.size)).cgPath.copy(using: &transform))
    }
}
