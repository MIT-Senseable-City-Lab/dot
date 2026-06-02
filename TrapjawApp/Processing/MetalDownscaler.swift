//
//  MetalDownscaler.swift
//  TrapjawApp
//
//  Real-time 4K→1080p downscaling using Metal compute shaders.
//  Provides fast GPU-accelerated conversion for trapjaw processing.
//

import Foundation
import Metal
import CoreVideo
import UIKit
import os.log

private let logger = Logger(subsystem: "com.trapjaw.downscaler", category: "MetalDownscaler")

enum DownscaleQuality {
    case nearest    // Fast, slight aliasing
    case average    // Balanced, good for detection
    case area       // Best quality, slightly slower
}

typealias DownscaleCompletion = (CVPixelBuffer?) -> Void

final class MetalDownscaler {
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState_nearest: MTLComputePipelineState
    private let pipelineState_average: MTLComputePipelineState
    private let pipelineState_area: MTLComputePipelineState
    
    // Output buffer pool (reusable buffers for 1080p output)
    private var outputBufferPool: CVPixelBufferPool?
    private let outputWidth: Int = 1920
    private let outputHeight: Int = 1080
    
    // Texture cache for CV->Metal conversion
    private var textureCache: CVMetalTextureCache?
    
    // MARK: - Init
    
    init?(device: MTLDevice? = nil) {
        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else {
            logger.error("Metal is not supported on this device")
            return nil
        }
        
        self.device = metalDevice
        guard let commandQueue = metalDevice.makeCommandQueue() else {
            logger.error("Failed to create Metal command queue")
            return nil
        }
        self.commandQueue = commandQueue
        
        // Create pipeline states from shader source
        do {
            let library = try Self.createShaderLibrary(device: metalDevice)
            
            guard let nearestFunction = library.makeFunction(name: "downscale2x_nearest"),
                  let averageFunction = library.makeFunction(name: "downscale2x_average"),
                  let areaFunction = library.makeFunction(name: "downscale2x_area") else {
                logger.error("Failed to load downscale shader functions")
                return nil
            }
            
            self.pipelineState_nearest = try metalDevice.makeComputePipelineState(function: nearestFunction)
            self.pipelineState_average = try metalDevice.makeComputePipelineState(function: averageFunction)
            self.pipelineState_area = try metalDevice.makeComputePipelineState(function: areaFunction)
        } catch {
            logger.error("Failed to create compute pipeline: \(error.localizedDescription)")
            return nil
        }
        
        // Create texture cache
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &textureCache)
        
        // Create output buffer pool
        createOutputBufferPool()
        
        logger.info("MetalDownscaler initialized for 4K→1080p (async)")
    }
    
    // MARK: - Shader Source
    
    private static func createShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        // Simple 2x downscale: sample every other pixel
        kernel void downscale2x_nearest(
            texture2d<float, access::read> input [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            uint2 inputCoord = gid * 2;
            float4 color = input.read(inputCoord);
            output.write(color, gid);
        }
        
        // High-quality downscale using 2x2 average
        kernel void downscale2x_average(
            texture2d<float, access::read> input [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            uint2 base = gid * 2;
            
            float4 c00 = input.read(base + uint2(0, 0));
            float4 c10 = input.read(base + uint2(1, 0));
            float4 c01 = input.read(base + uint2(0, 1));
            float4 c11 = input.read(base + uint2(1, 1));
            
            float4 avg = (c00 + c10 + c01 + c11) * 0.25;
            output.write(avg, gid);
        }
        
        // Area-based downscale for even better quality
        kernel void downscale2x_area(
            texture2d<float, access::read> input [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            uint2 center = gid * 2 + uint2(1, 1);
            
            float4 sum = float4(0.0);
            float weight = 0.0;
            
            for(int dy = -1; dy <= 1; dy++) {
                for(int dx = -1; dx <= 1; dx++) {
                    int2 coord = int2(center) + int2(dx, dy);
                    if(coord.x >= 0 && coord.y >= 0) {
                        float w = (dx == 0 && dy == 0) ? 4.0 : 1.0;
                        sum += input.read(uint2(coord)) * w;
                        weight += w;
                    }
                }
            }
            
            output.write(sum / weight, gid);
        }
        """
        
        return try device.makeLibrary(source: shaderSource, options: nil)
    }
    
    // MARK: - Public API (Async)
    
    /// Asynchronously downscale a 4K CVPixelBuffer to 1080p.
    /// - Parameters:
    ///   - inputBuffer: 4K input buffer (3840x2160)
    ///   - quality: Downscaling quality setting
    ///   - completion: Called on completion with 1080p buffer or nil on failure
    func downscale(inputBuffer: CVPixelBuffer, quality: DownscaleQuality = .average, completion: @escaping DownscaleCompletion) {
        let inputWidth = CVPixelBufferGetWidth(inputBuffer)
        let inputHeight = CVPixelBufferGetHeight(inputBuffer)
        
        // Validate input dimensions
        guard inputWidth == 3840 && inputHeight == 2160 else {
            logger.warning("Input buffer is not 4K: \(inputWidth)x\(inputHeight)")
            completion(nil)
            return
        }
        
        // Create output buffer
        var outputBuffer: CVPixelBuffer?
        guard let pool = outputBufferPool else {
            logger.error("Output buffer pool not initialized")
            completion(nil)
            return
        }
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        
        guard status == kCVReturnSuccess, let output = outputBuffer else {
            logger.error("Failed to create output pixel buffer")
            completion(nil)
            return
        }
        
        // Create Metal textures
        guard let inputTexture = createTexture(from: inputBuffer, format: .bgra8Unorm),
              let outputTexture = createTexture(from: output, format: .bgra8Unorm) else {
            logger.error("Failed to create Metal textures")
            completion(nil)
            return
        }
        
        // Select pipeline based on quality
        let pipelineState: MTLComputePipelineState
        switch quality {
        case .nearest:
            pipelineState = pipelineState_nearest
        case .average:
            pipelineState = pipelineState_average
        case .area:
            pipelineState = pipelineState_area
        }
        
        // Execute downscale
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            logger.error("Failed to create command buffer")
            completion(nil)
            return
        }
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        
        // Calculate thread groups
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (outputWidth + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (outputHeight + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        
        // Add async completion handler
        commandBuffer.addCompletedHandler { _ in
            
            // Check if command buffer completed successfully
            if commandBuffer.status == .completed {
                completion(output)
            } else {
                let statusValue = commandBuffer.status.rawValue
                logger.error("Metal command buffer failed with status: \(statusValue)")
                completion(nil)
            }
        }
        
        // Schedule command buffer
        commandBuffer.commit()
    }
    
    // MARK: - Private Helpers
    
    private func createOutputBufferPool() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        outputBufferPool = pool
    }
    
    private func createTexture(from pixelBuffer: CVPixelBuffer, format: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            0,
            &cvTexture
        )
        
        guard status == kCVReturnSuccess, let cvTexture = cvTexture else {
            return nil
        }
        
        return CVMetalTextureGetTexture(cvTexture)
    }
    
    /// Flush the Metal texture cache to prevent resource accumulation.
    /// Call periodically (e.g., every 60 frames) to avoid GPU memory pressure.
    func flushTextureCache() {
        guard let cache = textureCache else { return }
        CVMetalTextureCacheFlush(cache, 0)
    }
}
