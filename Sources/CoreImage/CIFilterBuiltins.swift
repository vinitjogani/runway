// The CIFilterBuiltins typed API (`import CoreImage.CIFilterBuiltins`): a
// protocol per filter with typed inputs, and CIFilter factory methods.
// Generated from one table (Tools-free: edit the table's shape if you add
// filters); each input reads and writes the filter's named keys.

import CoreGraphics
import Foundation

public protocol CIFilterProtocol: AnyObject { var outputImage: CIImage? { get } }

public protocol CIGaussianBlur: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var radius: Float { get set }
}
final class _CIGaussianBlurFilter: CIFilter, CIGaussianBlur, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var radius: Float {
        get { Float(double("inputRadius")) }
        set { values["inputRadius"] = Double(newValue) }
    }
}

public protocol CIBoxBlur: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var radius: Float { get set }
}
final class _CIBoxBlurFilter: CIFilter, CIBoxBlur, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var radius: Float {
        get { Float(double("inputRadius")) }
        set { values["inputRadius"] = Double(newValue) }
    }
}

public protocol CIColorControls: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var saturation: Float { get set }
    var brightness: Float { get set }
    var contrast: Float { get set }
}
final class _CIColorControlsFilter: CIFilter, CIColorControls, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var saturation: Float {
        get { Float(double("inputSaturation")) }
        set { values["inputSaturation"] = Double(newValue) }
    }
    var brightness: Float {
        get { Float(double("inputBrightness")) }
        set { values["inputBrightness"] = Double(newValue) }
    }
    var contrast: Float {
        get { Float(double("inputContrast")) }
        set { values["inputContrast"] = Double(newValue) }
    }
}

public protocol CIColorMatrix: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var rVector: CIVector { get set }
    var gVector: CIVector { get set }
    var bVector: CIVector { get set }
    var aVector: CIVector { get set }
    var biasVector: CIVector { get set }
}
final class _CIColorMatrixFilter: CIFilter, CIColorMatrix, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var rVector: CIVector {
        get { vector("inputRVector") ?? CIVector(x: 0, y: 0, z: 0, w: 0) }
        set { values["inputRVector"] = newValue }
    }
    var gVector: CIVector {
        get { vector("inputGVector") ?? CIVector(x: 0, y: 0, z: 0, w: 0) }
        set { values["inputGVector"] = newValue }
    }
    var bVector: CIVector {
        get { vector("inputBVector") ?? CIVector(x: 0, y: 0, z: 0, w: 0) }
        set { values["inputBVector"] = newValue }
    }
    var aVector: CIVector {
        get { vector("inputAVector") ?? CIVector(x: 0, y: 0, z: 0, w: 0) }
        set { values["inputAVector"] = newValue }
    }
    var biasVector: CIVector {
        get { vector("inputBiasVector") ?? CIVector(x: 0, y: 0, z: 0, w: 0) }
        set { values["inputBiasVector"] = newValue }
    }
}

public protocol CIExposureAdjust: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var ev: Float { get set }
}
final class _CIExposureAdjustFilter: CIFilter, CIExposureAdjust, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var ev: Float {
        get { Float(double("inputEV")) }
        set { values["inputEV"] = Double(newValue) }
    }
}

public protocol CIGammaAdjust: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var power: Float { get set }
}
final class _CIGammaAdjustFilter: CIFilter, CIGammaAdjust, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var power: Float {
        get { Float(double("inputPower")) }
        set { values["inputPower"] = Double(newValue) }
    }
}

public protocol CIColorInvert: CIFilterProtocol {
    var inputImage: CIImage? { get set }
}
final class _CIColorInvertFilter: CIFilter, CIColorInvert, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
}

public protocol CIColorMonochrome: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var color: CIColor { get set }
    var intensity: Float { get set }
}
final class _CIColorMonochromeFilter: CIFilter, CIColorMonochrome, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var color: CIColor {
        get { color("inputColor") }
        set { values["inputColor"] = newValue }
    }
    var intensity: Float {
        get { Float(double("inputIntensity")) }
        set { values["inputIntensity"] = Double(newValue) }
    }
}

public protocol CISepiaTone: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var intensity: Float { get set }
}
final class _CISepiaToneFilter: CIFilter, CISepiaTone, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var intensity: Float {
        get { Float(double("inputIntensity")) }
        set { values["inputIntensity"] = Double(newValue) }
    }
}

public protocol CIPhotoEffectMono: CIFilterProtocol {
    var inputImage: CIImage? { get set }
}
final class _CIPhotoEffectMonoFilter: CIFilter, CIPhotoEffectMono, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
}

public protocol CIMaskToAlpha: CIFilterProtocol {
    var inputImage: CIImage? { get set }
}
final class _CIMaskToAlphaFilter: CIFilter, CIMaskToAlpha, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
}

public protocol CIVignette: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var intensity: Float { get set }
    var radius: Float { get set }
}
final class _CIVignetteFilter: CIFilter, CIVignette, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var intensity: Float {
        get { Float(double("inputIntensity")) }
        set { values["inputIntensity"] = Double(newValue) }
    }
    var radius: Float {
        get { Float(double("inputRadius")) }
        set { values["inputRadius"] = Double(newValue) }
    }
}

public protocol CIAffineTransform: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var transform: CGAffineTransform { get set }
}
final class _CIAffineTransformFilter: CIFilter, CIAffineTransform, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var transform: CGAffineTransform {
        get { transform("inputTransform") }
        set { values["inputTransform"] = newValue }
    }
}

public protocol CIAffineClamp: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var transform: CGAffineTransform { get set }
}
final class _CIAffineClampFilter: CIFilter, CIAffineClamp, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var transform: CGAffineTransform {
        get { transform("inputTransform") }
        set { values["inputTransform"] = newValue }
    }
}

public protocol CILanczosScaleTransform: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var scale: Float { get set }
    var aspectRatio: Float { get set }
}
final class _CILanczosScaleTransformFilter: CIFilter, CILanczosScaleTransform, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var scale: Float {
        get { Float(double("inputScale")) }
        set { values["inputScale"] = Double(newValue) }
    }
    var aspectRatio: Float {
        get { Float(double("inputAspectRatio")) }
        set { values["inputAspectRatio"] = Double(newValue) }
    }
}

public protocol CICrop: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var rectangle: CIVector { get set }
}
final class _CICropFilter: CIFilter, CICrop, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var rectangle: CIVector {
        get { vector("inputRectangle") ?? CIVector(x: 0, y: 0, z: 0, w: 0) }
        set { values["inputRectangle"] = newValue }
    }
}

public protocol CIConstantColorGenerator: CIFilterProtocol {
    var color: CIColor { get set }
}
final class _CIConstantColorGeneratorFilter: CIFilter, CIConstantColorGenerator, @unchecked Sendable {
    var color: CIColor {
        get { color("inputColor") }
        set { values["inputColor"] = newValue }
    }
}

public protocol CILinearGradient: CIFilterProtocol {
    var point0: CGPoint { get set }
    var point1: CGPoint { get set }
    var color0: CIColor { get set }
    var color1: CIColor { get set }
}
final class _CILinearGradientFilter: CIFilter, CILinearGradient, @unchecked Sendable {
    var point0: CGPoint {
        get { vector("inputPoint0")?.cgPointValue ?? .zero }
        set { values["inputPoint0"] = CIVector(cgPoint: newValue) }
    }
    var point1: CGPoint {
        get { vector("inputPoint1")?.cgPointValue ?? .zero }
        set { values["inputPoint1"] = CIVector(cgPoint: newValue) }
    }
    var color0: CIColor {
        get { color("inputColor0") }
        set { values["inputColor0"] = newValue }
    }
    var color1: CIColor {
        get { color("inputColor1") }
        set { values["inputColor1"] = newValue }
    }
}

public protocol CISmoothLinearGradient: CIFilterProtocol {
    var point0: CGPoint { get set }
    var point1: CGPoint { get set }
    var color0: CIColor { get set }
    var color1: CIColor { get set }
}
final class _CISmoothLinearGradientFilter: CIFilter, CISmoothLinearGradient, @unchecked Sendable {
    var point0: CGPoint {
        get { vector("inputPoint0")?.cgPointValue ?? .zero }
        set { values["inputPoint0"] = CIVector(cgPoint: newValue) }
    }
    var point1: CGPoint {
        get { vector("inputPoint1")?.cgPointValue ?? .zero }
        set { values["inputPoint1"] = CIVector(cgPoint: newValue) }
    }
    var color0: CIColor {
        get { color("inputColor0") }
        set { values["inputColor0"] = newValue }
    }
    var color1: CIColor {
        get { color("inputColor1") }
        set { values["inputColor1"] = newValue }
    }
}

public protocol CIRadialGradient: CIFilterProtocol {
    var center: CGPoint { get set }
    var radius0: Float { get set }
    var radius1: Float { get set }
    var color0: CIColor { get set }
    var color1: CIColor { get set }
}
final class _CIRadialGradientFilter: CIFilter, CIRadialGradient, @unchecked Sendable {
    var center: CGPoint {
        get { vector("inputCenter")?.cgPointValue ?? .zero }
        set { values["inputCenter"] = CIVector(cgPoint: newValue) }
    }
    var radius0: Float {
        get { Float(double("inputRadius0")) }
        set { values["inputRadius0"] = Double(newValue) }
    }
    var radius1: Float {
        get { Float(double("inputRadius1")) }
        set { values["inputRadius1"] = Double(newValue) }
    }
    var color0: CIColor {
        get { color("inputColor0") }
        set { values["inputColor0"] = newValue }
    }
    var color1: CIColor {
        get { color("inputColor1") }
        set { values["inputColor1"] = newValue }
    }
}

public protocol CIRoundedRectangleGenerator: CIFilterProtocol {
    var extent: CGRect { get set }
    var radius: Float { get set }
    var color: CIColor { get set }
}
final class _CIRoundedRectangleGeneratorFilter: CIFilter, CIRoundedRectangleGenerator, @unchecked Sendable {
    var extent: CGRect {
        get { vector("inputExtent")?.cgRectValue ?? .zero }
        set { values["inputExtent"] = CIVector(cgRect: newValue) }
    }
    var radius: Float {
        get { Float(double("inputRadius")) }
        set { values["inputRadius"] = Double(newValue) }
    }
    var color: CIColor {
        get { color("inputColor") }
        set { values["inputColor"] = newValue }
    }
}

public protocol CIRandomGenerator: CIFilterProtocol {
}
final class _CIRandomGeneratorFilter: CIFilter, CIRandomGenerator, @unchecked Sendable {
}

public protocol CICheckerboardGenerator: CIFilterProtocol {
    var center: CGPoint { get set }
    var color0: CIColor { get set }
    var color1: CIColor { get set }
    var width: Float { get set }
    var sharpness: Float { get set }
}
final class _CICheckerboardGeneratorFilter: CIFilter, CICheckerboardGenerator, @unchecked Sendable {
    var center: CGPoint {
        get { vector("inputCenter")?.cgPointValue ?? .zero }
        set { values["inputCenter"] = CIVector(cgPoint: newValue) }
    }
    var color0: CIColor {
        get { color("inputColor0") }
        set { values["inputColor0"] = newValue }
    }
    var color1: CIColor {
        get { color("inputColor1") }
        set { values["inputColor1"] = newValue }
    }
    var width: Float {
        get { Float(double("inputWidth")) }
        set { values["inputWidth"] = Double(newValue) }
    }
    var sharpness: Float {
        get { Float(double("inputSharpness")) }
        set { values["inputSharpness"] = Double(newValue) }
    }
}

public protocol CIBlendWithMask: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
    var maskImage: CIImage? { get set }
}
final class _CIBlendWithMaskFilter: CIFilter, CIBlendWithMask, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
    var maskImage: CIImage? {
        get { values["inputMaskImage"] as? CIImage }
        set { values["inputMaskImage"] = newValue }
    }
}

public protocol CIBlendWithAlphaMask: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
    var maskImage: CIImage? { get set }
}
final class _CIBlendWithAlphaMaskFilter: CIFilter, CIBlendWithAlphaMask, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
    var maskImage: CIImage? {
        get { values["inputMaskImage"] as? CIImage }
        set { values["inputMaskImage"] = newValue }
    }
}

public protocol CISourceOverCompositing: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CISourceOverCompositingFilter: CIFilter, CISourceOverCompositing, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CISourceOutCompositing: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CISourceOutCompositingFilter: CIFilter, CISourceOutCompositing, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CISourceInCompositing: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CISourceInCompositingFilter: CIFilter, CISourceInCompositing, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CISourceAtopCompositing: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CISourceAtopCompositingFilter: CIFilter, CISourceAtopCompositing, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CIAdditionCompositing: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CIAdditionCompositingFilter: CIFilter, CIAdditionCompositing, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CIMultiplyCompositing: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CIMultiplyCompositingFilter: CIFilter, CIMultiplyCompositing, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CIMinimumCompositing: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CIMinimumCompositingFilter: CIFilter, CIMinimumCompositing, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CIMaximumCompositing: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CIMaximumCompositingFilter: CIFilter, CIMaximumCompositing, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CIMultiplyBlendMode: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CIMultiplyBlendModeFilter: CIFilter, CIMultiplyBlendMode, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CIScreenBlendMode: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CIScreenBlendModeFilter: CIFilter, CIScreenBlendMode, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CIDarkenBlendMode: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CIDarkenBlendModeFilter: CIFilter, CIDarkenBlendMode, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CILightenBlendMode: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CILightenBlendModeFilter: CIFilter, CILightenBlendMode, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

public protocol CIDifferenceBlendMode: CIFilterProtocol {
    var inputImage: CIImage? { get set }
    var backgroundImage: CIImage? { get set }
}
final class _CIDifferenceBlendModeFilter: CIFilter, CIDifferenceBlendMode, @unchecked Sendable {
    var inputImage: CIImage? {
        get { values["inputImage"] as? CIImage }
        set { values["inputImage"] = newValue }
    }
    var backgroundImage: CIImage? {
        get { values["inputBackgroundImage"] as? CIImage }
        set { values["inputBackgroundImage"] = newValue }
    }
}

extension CIFilter {
    public static func gaussianBlur() -> CIFilter & CIGaussianBlur { _CIGaussianBlurFilter(builtin: "CIGaussianBlur") }
    public static func boxBlur() -> CIFilter & CIBoxBlur { _CIBoxBlurFilter(builtin: "CIBoxBlur") }
    public static func colorControls() -> CIFilter & CIColorControls { _CIColorControlsFilter(builtin: "CIColorControls") }
    public static func colorMatrix() -> CIFilter & CIColorMatrix { _CIColorMatrixFilter(builtin: "CIColorMatrix") }
    public static func exposureAdjust() -> CIFilter & CIExposureAdjust { _CIExposureAdjustFilter(builtin: "CIExposureAdjust") }
    public static func gammaAdjust() -> CIFilter & CIGammaAdjust { _CIGammaAdjustFilter(builtin: "CIGammaAdjust") }
    public static func colorInvert() -> CIFilter & CIColorInvert { _CIColorInvertFilter(builtin: "CIColorInvert") }
    public static func colorMonochrome() -> CIFilter & CIColorMonochrome { _CIColorMonochromeFilter(builtin: "CIColorMonochrome") }
    public static func sepiaTone() -> CIFilter & CISepiaTone { _CISepiaToneFilter(builtin: "CISepiaTone") }
    public static func photoEffectMono() -> CIFilter & CIPhotoEffectMono { _CIPhotoEffectMonoFilter(builtin: "CIPhotoEffectMono") }
    public static func maskToAlpha() -> CIFilter & CIMaskToAlpha { _CIMaskToAlphaFilter(builtin: "CIMaskToAlpha") }
    public static func vignette() -> CIFilter & CIVignette { _CIVignetteFilter(builtin: "CIVignette") }
    public static func affineTransform() -> CIFilter & CIAffineTransform { _CIAffineTransformFilter(builtin: "CIAffineTransform") }
    public static func affineClamp() -> CIFilter & CIAffineClamp { _CIAffineClampFilter(builtin: "CIAffineClamp") }
    public static func lanczosScaleTransform() -> CIFilter & CILanczosScaleTransform { _CILanczosScaleTransformFilter(builtin: "CILanczosScaleTransform") }
    public static func crop() -> CIFilter & CICrop { _CICropFilter(builtin: "CICrop") }
    public static func constantColorGenerator() -> CIFilter & CIConstantColorGenerator { _CIConstantColorGeneratorFilter(builtin: "CIConstantColorGenerator") }
    public static func linearGradient() -> CIFilter & CILinearGradient { _CILinearGradientFilter(builtin: "CILinearGradient") }
    public static func smoothLinearGradient() -> CIFilter & CISmoothLinearGradient { _CISmoothLinearGradientFilter(builtin: "CISmoothLinearGradient") }
    public static func radialGradient() -> CIFilter & CIRadialGradient { _CIRadialGradientFilter(builtin: "CIRadialGradient") }
    public static func roundedRectangleGenerator() -> CIFilter & CIRoundedRectangleGenerator { _CIRoundedRectangleGeneratorFilter(builtin: "CIRoundedRectangleGenerator") }
    public static func randomGenerator() -> CIFilter & CIRandomGenerator { _CIRandomGeneratorFilter(builtin: "CIRandomGenerator") }
    public static func checkerboardGenerator() -> CIFilter & CICheckerboardGenerator { _CICheckerboardGeneratorFilter(builtin: "CICheckerboardGenerator") }
    public static func blendWithMask() -> CIFilter & CIBlendWithMask { _CIBlendWithMaskFilter(builtin: "CIBlendWithMask") }
    public static func blendWithAlphaMask() -> CIFilter & CIBlendWithAlphaMask { _CIBlendWithAlphaMaskFilter(builtin: "CIBlendWithAlphaMask") }
    public static func sourceOverCompositing() -> CIFilter & CISourceOverCompositing { _CISourceOverCompositingFilter(builtin: "CISourceOverCompositing") }
    public static func sourceOutCompositing() -> CIFilter & CISourceOutCompositing { _CISourceOutCompositingFilter(builtin: "CISourceOutCompositing") }
    public static func sourceInCompositing() -> CIFilter & CISourceInCompositing { _CISourceInCompositingFilter(builtin: "CISourceInCompositing") }
    public static func sourceAtopCompositing() -> CIFilter & CISourceAtopCompositing { _CISourceAtopCompositingFilter(builtin: "CISourceAtopCompositing") }
    public static func additionCompositing() -> CIFilter & CIAdditionCompositing { _CIAdditionCompositingFilter(builtin: "CIAdditionCompositing") }
    public static func multiplyCompositing() -> CIFilter & CIMultiplyCompositing { _CIMultiplyCompositingFilter(builtin: "CIMultiplyCompositing") }
    public static func minimumCompositing() -> CIFilter & CIMinimumCompositing { _CIMinimumCompositingFilter(builtin: "CIMinimumCompositing") }
    public static func maximumCompositing() -> CIFilter & CIMaximumCompositing { _CIMaximumCompositingFilter(builtin: "CIMaximumCompositing") }
    public static func multiplyBlendMode() -> CIFilter & CIMultiplyBlendMode { _CIMultiplyBlendModeFilter(builtin: "CIMultiplyBlendMode") }
    public static func screenBlendMode() -> CIFilter & CIScreenBlendMode { _CIScreenBlendModeFilter(builtin: "CIScreenBlendMode") }
    public static func darkenBlendMode() -> CIFilter & CIDarkenBlendMode { _CIDarkenBlendModeFilter(builtin: "CIDarkenBlendMode") }
    public static func lightenBlendMode() -> CIFilter & CILightenBlendMode { _CILightenBlendModeFilter(builtin: "CILightenBlendMode") }
    public static func differenceBlendMode() -> CIFilter & CIDifferenceBlendMode { _CIDifferenceBlendModeFilter(builtin: "CIDifferenceBlendMode") }
}
