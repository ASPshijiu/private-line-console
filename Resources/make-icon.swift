import AppKit
let directory=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
for (size,scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels=CGFloat(size*scale)
    let image=NSImage(size:NSSize(width:pixels,height:pixels))
    image.lockFocus()
    let box=NSRect(x:pixels*0.07,y:pixels*0.07,width:pixels*0.86,height:pixels*0.86)
    let background=NSBezierPath(roundedRect:box,xRadius:pixels*0.2,yRadius:pixels*0.2)
    NSGradient(colors:[NSColor(srgbRed:0.20,green:0.30,blue:0.92,alpha:1),NSColor(srgbRed:0.51,green:0.24,blue:0.89,alpha:1)])!.draw(in:background,angle:55)
    let route=NSBezierPath();route.lineWidth=pixels*0.065;route.lineCapStyle = .round
    route.move(to:NSPoint(x:pixels*0.26,y:pixels*0.34))
    route.curve(to:NSPoint(x:pixels*0.5,y:pixels*0.66),controlPoint1:NSPoint(x:pixels*0.43,y:pixels*0.34),controlPoint2:NSPoint(x:pixels*0.32,y:pixels*0.66))
    route.curve(to:NSPoint(x:pixels*0.75,y:pixels*0.41),controlPoint1:NSPoint(x:pixels*0.68,y:pixels*0.66),controlPoint2:NSPoint(x:pixels*0.60,y:pixels*0.41))
    NSColor.white.withAlphaComponent(0.92).setStroke();route.stroke()
    for (x,y) in [(0.26,0.34),(0.5,0.66),(0.75,0.41)] {
        NSColor.white.setFill();NSBezierPath(ovalIn:NSRect(x:pixels*(x-0.065),y:pixels*(y-0.065),width:pixels*0.13,height:pixels*0.13)).fill()
    }
    image.unlockFocus()
    let png=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
    let suffix=scale==2 ? "@2x":""
    try png.write(to:directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
}
