//
//  Data+Compression.swift
//  CloudData
//
//  Created by Artem Shimanski on 08.08.2018.
//  Copyright © 2018 Artem Shimanski. All rights reserved.
//

import Foundation
import Compression
import CommonCrypto

let bufferSize = 4096

public enum ZLIBCompressionLevel {
	case `default`
	case bestCompression
	case bestSpeed
	var level: Int32 {
		switch self {
		case .default:
			return Z_DEFAULT_COMPRESSION
		case .bestCompression:
			return Z_BEST_COMPRESSION
		case .bestSpeed:
			return Z_BEST_SPEED
		}
	}
}

public enum CompressionAlgorithm {
	case lz4
	case zlibraw
	case zlib(ZLIBCompressionLevel)
	case lzma
	case lz4raw
	case lzfse
	public var algorithm: compression_algorithm? {
		switch self {
		case .lz4:
			return COMPRESSION_LZ4
		case .zlibraw:
			return COMPRESSION_ZLIB
		case .zlib:
			return nil
		case .lzma:
			return COMPRESSION_LZMA
		case .lz4raw:
			return COMPRESSION_LZ4_RAW
		case .lzfse:
			return COMPRESSION_LZFSE
		}
	}
}

enum CompressionError: Error {
	case initError
	case processError
}

extension Data {
	
	public func md5() -> Data {
		let result = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(CC_MD5_DIGEST_LENGTH))
		defer{result.deallocate()}
		withUnsafeBytes { ptr in
			_ = CC_MD5(ptr, CC_LONG(self.count), result.baseAddress!)
		}
		return Data(buffer: result)
	}
	
	public func compressed(algorithm: CompressionAlgorithm) throws -> Data  {
		switch algorithm {
		case let .zlib(level):
			return try processed(comporessionLevel: level, encode: true)
		default:
			return try processed(algorithm: algorithm.algorithm!, operation: COMPRESSION_STREAM_ENCODE, flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
		}
	}
	
	public func decompressed(algorithm: CompressionAlgorithm) throws -> Data {
		switch algorithm {
		case let .zlib(level):
			return try processed(comporessionLevel: level, encode: false)
		default:
			return try processed(algorithm: algorithm.algorithm!, operation: COMPRESSION_STREAM_DECODE, flags: 0)
		}
	}
	
	private func processed(algorithm: compression_algorithm, operation: compression_stream_operation, flags: Int32) throws -> Data {
		var data = DispatchData.empty
		
		
		try withUnsafeBytes { (ptr: UnsafePointer<UInt8>) in
			var stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
			
			defer {stream.deallocate()}
			
			guard compression_stream_init(stream, operation, algorithm) == COMPRESSION_STATUS_OK else {throw CompressionError.initError }
			
			var buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
			defer { buffer.deallocate() }

			stream.pointee.src_ptr = ptr
			stream.pointee.src_size = count
			stream.pointee.dst_size = bufferSize
			stream.pointee.dst_ptr = buffer.baseAddress!
			
			defer { compression_stream_destroy(stream) }
			
			var status = COMPRESSION_STATUS_OK
			repeat {
				status = compression_stream_process(stream, flags)
				guard status != COMPRESSION_STATUS_ERROR else {throw CompressionError.processError}
				let count = bufferSize - stream.pointee.dst_size
				guard count > 0 else {throw CompressionError.processError}
				data.append(UnsafeBufferPointer(rebasing: buffer[..<count]))
				stream.pointee.dst_ptr = buffer.baseAddress!
				stream.pointee.dst_size = bufferSize
			} while status == COMPRESSION_STATUS_OK
		}
		
		return data.withUnsafeBytes(body: { ptr -> Data in
			Data(bytes: ptr, count: data.count)
		})
	}
	
	private func processed(comporessionLevel: ZLIBCompressionLevel, encode: Bool) throws -> Data {
		var data = DispatchData.empty
		
		var copy = self
		
		try copy.withUnsafeMutableBytes { (ptr: UnsafeMutablePointer<Bytef>) in
			var strm = z_stream(next_in: nil, avail_in: 0, total_in: 0, next_out: nil, avail_out: 0, total_out: 0, msg: nil, state: nil, zalloc: nil, zfree: nil, opaque: nil, data_type: 0, adler: 0, reserved: 0)
			try withUnsafeMutablePointer(to: &strm) { strmp in
				if encode {
					guard deflateInit_(strmp, comporessionLevel.level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {throw CompressionError.initError}
				}
				else {
					guard inflateInit_(strmp, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {throw CompressionError.initError}
				}
				
				var buffer = UnsafeMutableBufferPointer<Bytef>.allocate(capacity: bufferSize)
				defer { buffer.deallocate() }

				strmp.pointee.next_in = ptr
				strmp.pointee.avail_in = UInt32(self.count)
				
				repeat {
					strmp.pointee.next_out = buffer.baseAddress
					strmp.pointee.avail_out = UInt32(bufferSize)
					let result: Int32 = encode ? deflate(strmp, Z_FINISH) : inflate(strmp, Z_NO_FLUSH)
					guard result == Z_OK || result == Z_STREAM_END else { throw CompressionError.processError }
					let count = bufferSize - Int(strmp.pointee.avail_out)
					data.append(UnsafeBufferPointer(rebasing: buffer[..<count]))
				}
				while strmp.pointee.avail_out == 0
			}
		}
		
		return data.withUnsafeBytes(body: { ptr -> Data in
			Data(bytes: ptr, count: data.count)
		})

	}
}
