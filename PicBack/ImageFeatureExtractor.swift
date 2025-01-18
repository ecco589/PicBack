import Vision
import CoreML

class ImageFeatureExtractor {
    static func extractFeatures(from image: CGImage) throws -> [Float] {
        let requestHandler = VNImageRequestHandler(cgImage: image)
        let request = VNFeaturePrintObservationRequest()
        
        try requestHandler.perform([request])
        
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw NSError(domain: "ImageFeatureExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract features"])
        }
        
        var features: [Float] = Array(repeating: 0, count: 512)
        try observation.copy(to: &features)
        
        return features
    }
} 