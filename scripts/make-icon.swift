// Draws the app icon: swift scripts/make-icon.swift out.png, then build an .icns with iconutil.
import AppKit
let S = 1024
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rs = CGColorSpace(name: CGColorSpace.sRGB)!
func g(_ a:[CGFloat],_ b:[CGFloat]) -> CGGradient { CGGradient(colorsSpace: rs, colors: [CGColor(colorSpace: rs, components: a)!, CGColor(colorSpace: rs, components: b)!] as CFArray, locations: [0,1])! }
let bg = CGPath(roundedRect: CGRect(x:100,y:100,width:824,height:824), cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState(); ctx.addPath(bg); ctx.clip(); ctx.drawLinearGradient(g([0.20,0.62,0.86,1],[0.05,0.22,0.42,1]), start: CGPoint(x:300,y:924), end: CGPoint(x:724,y:100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); ctx.restoreGState()
func disc(_ c: CGPoint,_ r: CGFloat,_ top:[CGFloat],_ bot:[CGFloat]) { ctx.saveGState(); ctx.addEllipse(in: CGRect(x:c.x-r,y:c.y-r,width:2*r,height:2*r)); ctx.clip(); ctx.drawLinearGradient(g(top,bot), start: CGPoint(x:c.x-r*0.6,y:c.y+r), end: CGPoint(x:c.x+r*0.6,y:c.y-r), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); ctx.restoreGState() }
let c = CGPoint(x:512,y:512)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width:14,height:-26), blur: 44, color: CGColor(gray:0,alpha:0.5)); ctx.setFillColor(gray:0.9,alpha:1); ctx.fillEllipse(in: CGRect(x:202,y:202,width:620,height:620)); ctx.restoreGState()
disc(c,310,[1,1,1,1],[0.62,0.63,0.66,1])
disc(c,232,[0.26,0.27,0.30,1],[0.03,0.03,0.04,1])
let t = CGPoint(x:512,y:590)
disc(t,92,[0.92,0.92,0.93,1],[0.55,0.56,0.58,1])
disc(t,66,[0.20,0.21,0.24,1],[0.01,0.01,0.02,1])
ctx.setStrokeColor(CGColor(colorSpace: rs, components:[0.36,0.84,0.98,1])!); ctx.setLineWidth(7); ctx.strokeEllipse(in: CGRect(x:t.x-77,y:t.y-77,width:154,height:154))
let r = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! r.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
