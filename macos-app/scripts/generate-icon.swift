// 原创矢量品牌图标，全部尺寸直接渲染，不读取第三方资源，by AI.Coding。
import Foundation
import CoreGraphics
import ImageIO
let directory=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
for (name,size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let space=CGColorSpaceCreateDeviceRGB()
    let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    let background=CGPath(roundedRect:.init(x:80,y:80,width:864,height:864),cornerWidth:190,cornerHeight:190,transform:nil)
    context.saveGState(); context.setShadow(offset:.init(width:0,height:-12),blur:35,color:CGColor(gray:0,alpha:0.20))
    context.addPath(background); context.setFillColor(CGColor(red:0.94,green:0.29,blue:0.39,alpha:1)); context.fillPath(); context.restoreGState()
    context.saveGState(); context.addPath(background); context.clip()
    let gradient=CGGradient(colorsSpace:space,colors:[CGColor(red:0.99,green:0.39,blue:0.43,alpha:1),CGColor(red:0.89,green:0.20,blue:0.35,alpha:1)] as CFArray,locations:[0,1])!
    context.drawLinearGradient(gradient,start:.init(x:150,y:940),end:.init(x:900,y:80),options:[]); context.restoreGState()
    context.setStrokeColor(CGColor(gray:1,alpha:0.97)); context.setLineWidth(34)
    context.addPath(CGPath(roundedRect:.init(x:345,y:353,width:365,height:365),cornerWidth:53,cornerHeight:53,transform:nil)); context.strokePath()
    context.setFillColor(CGColor(gray:1,alpha:1)); context.addPath(CGPath(roundedRect:.init(x:255,y:263,width:365,height:365),cornerWidth:53,cornerHeight:53,transform:nil)); context.fillPath()
    let image=context.makeImage()!,url=directory.appendingPathComponent(name+".png")
    let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("icon encoding failed") }
}
