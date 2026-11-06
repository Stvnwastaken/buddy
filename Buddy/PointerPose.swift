import CoreGraphics

struct PointerPose: Equatable {
    static let size = CGSize(width: 19, height: 20)

    let position: CGPoint
    let rotation: Double
    let target: CGPoint

    init(pointingAt point: CGPoint, in screen: CGRect) {
        target = CGPoint(x: point.x - screen.minX, y: screen.maxY - point.y)
        let clearance: CGFloat = 18
        let horizontal: CGFloat = target.x < 24 ? 1 : (target.x > screen.width - 24 ? -1 : 0)
        let vertical: CGFloat = target.y > screen.height - clearance - Self.size.height ? -1 : 1
        let length = hypot(horizontal, vertical)
        let x = horizontal / length
        let y = vertical / length
        let distance = clearance + Self.size.height / 2
        position = CGPoint(x: target.x + x * distance, y: target.y + y * distance)
        rotation = atan2(-x, y) * 180 / .pi
    }
}
