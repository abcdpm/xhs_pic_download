//
//  LivePhotoImporter.swift
//  把「静止帧 + 视频」合成为 Live Photo 并写入 macOS 照片图库。
//
//  WHY: iOS 端没有任何原生能力现场把两个文件合成为 Live Photo；
//  而 exiftool 又无法给小红书 CDN 的图片新建 Apple MakerNote（ContentIdentifier），
//  所以走官方 API：PHAssetCreationRequest + .photo + .pairedVideo，
//  Asset Identifier 由 Photos 自己生成，写入后随 iCloud 照片同步到 iPhone。
//
//  编译：./build.sh            （产物 livephoto/bin/lpimport）
//  用法：lpimport --image a.jpg --video a.mov [--album "小红书"] [--date 2024-09-04T20:53:34Z] [--quiet]
//
//  注意：本文件是 swiftc 单文件可执行入口，顶层代码就是 main，请勿改动文件顺序。
//

import Foundation
import AVFoundation
import ImageIO
import Photos

struct Options {
    var image: String?
    var video: String?
    var album: String?
    var date: Date?
    var identifier: String?
    var maxPixel: Int = 0
    var compose = true
    var dump = false
    var quiet = false
}

let usageLines = [
    "usage: lpimport --image <still.jpg> --video <live.mov> [options]",
    "",
    "  --image, -i  静止帧图片（JPEG/HEIC）",
    "  --video, -v  配对视频（H.264 .mov/.mp4，建议 3 秒）",
    "  --album, -a  导入后加入（必要时创建）的相簿名",
    "  --date       照片拍摄时间，ISO8601，如 2024-09-04T20:53:34Z",
    "  --identifier 写入静止帧 Apple MakerNote 的 Live Photo 标识（UUID），须与视频的一致",
    "  --max-pixel  静止帧最长边不超过该像素（0 表示不缩放，需配合 --identifier）",
    "  --dump       打印静止帧的元数据（含 MakerApple），用于排查配对失败",
    "  --no-compose 跳过 AVAssetWriter 重写视频（默认会补 still-image-time 轨）",
    "  --quiet, -q  不输出 warning",
    "  --version, -V 打印版本号",
]

// 版本信息来自 build.sh 注入并嵌入 __TEXT,__info_plist 的 Info.plist
func infoValue(_ key: String) -> String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) else { return nil }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func toolVersion() -> String {
    return infoValue("CFBundleShortVersionString") ?? "unknown"
}

func toolBuild() -> String {
    return infoValue("CFBundleVersion") ?? "unknown"
}

func versionLine() -> String {
    return "lpimport \(toolVersion()) (build \(toolBuild()))"
}

func logStderr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    logStderr("[lpimport] error: \(message)")
    emit(["ok": false, "error": message])
    exit(code)
}

func parseOptions(_ argv: [String]) -> Options {
    var options = Options()
    var index = 0

    func nextValue() -> String? {
        index += 1
        guard index < argv.count else { return nil }
        return argv[index]
    }

    while index < argv.count {
        let key = argv[index]
        switch key {
        case "--image", "-i":
            options.image = nextValue()
        case "--video", "-v":
            options.video = nextValue()
        case "--album", "-a":
            options.album = nextValue()
        case "--date":
            if let raw = nextValue() {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var parsed = formatter.date(from: raw)
                if parsed == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    parsed = formatter.date(from: raw)
                }
                if let date = parsed {
                    options.date = date
                } else {
                    logStderr("[lpimport] warn: 无法解析日期 \(raw)，忽略")
                }
            }
        case "--identifier":
            options.identifier = nextValue()
        case "--no-compose":
            options.compose = false
        case "--dump":
            options.dump = true
        case "--max-pixel":
            if let raw = nextValue(), let value = Int(raw) {
                options.maxPixel = value
            }
        case "--quiet", "-q":
            options.quiet = true
        case "--version", "-V":
            print(versionLine())
            exit(0)
        case "--help", "-h":
            print(versionLine())
            print(usageLines.joined(separator: "\n"))
            exit(0)
        default:
            logStderr("[lpimport] warn: 忽略未知参数 \(key)")
        }
        index += 1
    }
    return options
}

// MARK: - Photos 权限

/// 请求「添加到照片图库」权限。
/// 首次运行会弹一次系统授权框；如果是从 launchd 启动且没弹框，
/// 说明该进程拿不到 TCC 授权，请改为在 Terminal / tmux 中启动。
func requestPhotosAccess() -> PHAuthorizationStatus {
    if #available(macOS 11.0, *) {
        var status: PHAuthorizationStatus = .notDetermined
        let semaphore = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { result in
            status = result
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 120)
        return status
    }
    return PHPhotoLibrary.authorizationStatus()
}

// MARK: - 相簿

func findAlbumIdentifier(named name: String) -> String? {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "title == %@", name)
    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
    return collections.firstObject?.localIdentifier
}

func createAlbum(named name: String) -> String? {
    var identifier: String?
    let semaphore = DispatchSemaphore(value: 0)
    PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
        identifier = request.placeholderForCreatedAssetCollection.localIdentifier
    }, completionHandler: { _, error in
        if let error = error {
            logStderr("[lpimport] warn: 创建相簿失败 \(error.localizedDescription)")
        }
        semaphore.signal()
    })
    semaphore.wait()
    return identifier
}

func addAsset(_ assetIdentifier: String, toAlbum albumIdentifier: String) {
    guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumIdentifier], options: nil).firstObject else {
        logStderr("[lpimport] warn: 相簿不存在 \(albumIdentifier)")
        return
    }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
    let semaphore = DispatchSemaphore(value: 0)
    PHPhotoLibrary.shared().performChanges({
        guard let change = PHAssetCollectionChangeRequest(for: collection) else { return }
        change.addAssets(assets)
    }, completionHandler: { _, error in
        if let error = error {
            logStderr("[lpimport] warn: 加入相簿失败 \(error.localizedDescription)")
        }
        semaphore.signal()
    })
    semaphore.wait()
}

// MARK: - 给静止帧写入 Live Photo 标识（Apple MakerNote tag 17）
//
// PhotoKit 配对「静止帧 + 视频」时要求两端的 asset identifier 一致：
//   - 视频：QuickTime Keys 里的 com.apple.quicktime.content.identifier
//   - 静止帧：EXIF 里 Apple MakerNote 的 tag 17（ContentIdentifier）
// 静止帧这一半 exiftool 写不了（无法新建 MakerNote），但 ImageIO 可以：
// CGImageDestination 支持 kCGImagePropertyMakerAppleDictionary。
// 写完会读回校验，确认 tag 17 真的写进去了才继续。

func writeJPEG(cgImage: CGImage, to url: URL, makerApple: [AnyHashable: Any]) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
        throw NSError(domain: "lpimport", code: 14, userInfo: [
            NSLocalizedDescriptionKey: "无法创建输出图片：\(url.path)"
        ])
    }
    let properties: [CFString: Any] = [
        kCGImagePropertyMakerAppleDictionary: makerApple,
        kCGImageDestinationLossyCompressionQuality: 0.95,
    ]
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "lpimport", code: 15, userInfo: [
            NSLocalizedDescriptionKey: "写出 JPEG 失败：\(url.path)"
        ])
    }
}

func dumpImageProperties(_ label: String, _ url: URL) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
        logStderr("[lpimport] dump \(label): 读取失败 \(url.path)")
        return
    }
    let names = properties.keys.map { String(describing: $0) }.sorted()
    logStderr("[lpimport] dump \(label): keys=\(names.joined(separator: ","))")
    if let makerApple = properties[kCGImagePropertyMakerAppleDictionary] {
        logStderr("[lpimport] dump \(label): MakerApple=\(makerApple)")
    } else {
        logStderr("[lpimport] dump \(label): 没有 MakerApple")
    }
}

func readMakerAppleIdentifier(from url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [AnyHashable: Any]
    else {
        return nil
    }
    if let value = makerApple[17] as? String { return value }
    if let value = makerApple["17"] as? String { return value }
    return nil
}

func writeTaggedStill(from source: URL, to destination: URL, identifier: String, maxPixel: Int) throws {
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
        throw NSError(domain: "lpimport", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "无法读取静止帧：\(source.path)"
        ])
    }
    var options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    if maxPixel > 0 {
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
    }
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
        throw NSError(domain: "lpimport", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "无法解码静止帧（HEIC/WebP 需要系统支持）：\(source.path)"
        ])
    }

    // MakerApple 字典的 key 形式在不同系统上表现不同，两种都试，写完读回校验
    let keyForms: [(label: String, dict: [AnyHashable: Any])] = [
        ("数字 17", [17: identifier]),
        ("字符串 \"17\"", ["17": identifier]),
    ]
    var lastError: Error?
    for form in keyForms {
        do {
            try writeJPEG(cgImage: cgImage, to: destination, makerApple: form.dict)
            if readMakerAppleIdentifier(from: destination) == identifier {
                return
            }
            lastError = NSError(domain: "lpimport", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "写入 MakerApple 后读回校验失败（key: \(form.label)）"
            ])
        } catch {
            lastError = error
        }
    }
    throw lastError ?? NSError(domain: "lpimport", code: 13, userInfo: [
        NSLocalizedDescriptionKey: "无法给静止帧写入 Live Photo 标识"
    ])
}

// MARK: - 用 AVAssetWriter 重写视频，补出 Live Photo 需要的 still-image-time 轨
//
// iPhone 拍的 Live Photo，MOV 里除 com.apple.quicktime.content.identifier 之外，
// 还有一条 mdta 定时元数据轨 "com.apple.quicktime.still-image-time"（标记封面时刻）。
// ffmpeg 只能写 movie-level 的键，写不出这条轨；缺了它 Photos 会报 3302。
// 这里用 AVAssetWriter 以「原样 passthrough」方式重封装，并补出该轨。

func makeStillImageTimeFormat() -> CMFormatDescription? {
    let specs: [[String: Any]] = [
        [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                "com.apple.metadata.datatype.int8",
        ]
    ]
    var format: CMFormatDescription?
    let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: specs as CFArray,
        formatDescriptionOut: &format
    )
    if status != noErr {
        logStderr("[lpimport] warn: 创建 still-image-time 格式描述失败 status=\(status)")
        return nil
    }
    return format
}

func rewriteMovie(input: URL, output: URL, identifier: String) throws {
    let asset = AVURLAsset(url: input)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        throw NSError(domain: "lpimport", code: 20, userInfo: [
            NSLocalizedDescriptionKey: "视频里没有视频轨：\(input.path)"
        ])
    }

    let seconds = CMTimeGetSeconds(asset.duration)
    let stillTime = (seconds.isFinite && seconds > 0) ? seconds / 2.0 : 1.5

    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: output, fileType: .mov)
    } catch {
        throw NSError(domain: "lpimport", code: 21, userInfo: [
            NSLocalizedDescriptionKey: "无法创建 AVAssetReader/Writer：\(error.localizedDescription)"
        ])
    }

    // ---- 视频：解压成 BGRA 再用 H.264 重编码 ----
    // 不使用 passthrough（本机 macOS 上 passthrough 读不到样本），也不依赖
    // track.formatDescriptions（[Any] 里的 CF 类型无法安全转型）。
    let pixelWidth = Int(videoTrack.naturalSize.width.rounded())
    let pixelHeight = Int(videoTrack.naturalSize.height.rounded())
    guard pixelWidth > 0, pixelHeight > 0 else {
        throw NSError(domain: "lpimport", code: 22, userInfo: [
            NSLocalizedDescriptionKey: "视频尺寸异常：\(videoTrack.naturalSize)"
        ])
    }

    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    guard reader.canAdd(videoOutput) else {
        throw NSError(domain: "lpimport", code: 23, userInfo: [
            NSLocalizedDescriptionKey: "无法添加视频读取输出"
        ])
    }
    reader.add(videoOutput)

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: pixelWidth,
        AVVideoHeightKey: pixelHeight,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 8_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
    ])
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = videoTrack.preferredTransform
    guard writer.canAdd(videoInput) else {
        throw NSError(domain: "lpimport", code: 24, userInfo: [
            NSLocalizedDescriptionKey: "无法添加视频写入输入"
        ])
    }
    writer.add(videoInput)

    // ---- 音频（可选）：有音轨就尝试 passthrough，拿不到首帧格式就放弃音频 ----
    var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
    var audioOutputRef: AVAssetReaderTrackOutput?
    if let audioTrack = asset.tracks(withMediaType: .audio).first {
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        if reader.canAdd(audioOutput) {
            reader.add(audioOutput)
            audioOutputRef = audioOutput
        } else {
            logStderr("[lpimport] warn: 无法添加音频读取输出，本次不保留音频")
        }
    }

    // 1) content.identifier
    let identifierItem = AVMutableMetadataItem()
    identifierItem.keySpace = AVMetadataKeySpace.quickTimeMetadata
    identifierItem.key = "com.apple.quicktime.content.identifier" as NSString
    identifierItem.value = identifier as NSString
    writer.metadata = [identifierItem]

    // 2) still-image-time 定时元数据轨
    var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
    if let format = makeStillImageTimeFormat() {
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        metadataInput.expectsMediaDataInRealTime = false
        if writer.canAdd(metadataInput) {
            writer.add(metadataInput)
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        } else {
            logStderr("[lpimport] warn: 无法添加 still-image-time 轨")
        }
    }

    // 启动读取：音频需要首帧的格式描述（视频走重编码，不需要）
    guard reader.startReading() else {
        throw reader.error ?? NSError(domain: "lpimport", code: 26, userInfo: [
            NSLocalizedDescriptionKey: "AVAssetReader startReading 失败"
        ])
    }
    var audioFirstSample: CMSampleBuffer?
    if let audioOutput = audioOutputRef {
        if let sample = audioOutput.copyNextSampleBuffer(),
           let format = CMSampleBufferGetFormatDescription(sample) {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            audioInput.expectsMediaDataInRealTime = false
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                audioPair = (audioOutput, audioInput)
                audioFirstSample = sample
            } else {
                logStderr("[lpimport] warn: 无法添加音频写入输入，本次不保留音频")
            }
        } else {
            logStderr("[lpimport] warn: 音频首帧不可读，本次不保留音频")
        }
    }

    guard writer.startWriting() else {
        throw writer.error ?? NSError(domain: "lpimport", code: 23, userInfo: [
            NSLocalizedDescriptionKey: "AVAssetWriter startWriting 失败"
        ])
    }
    writer.startSession(atSourceTime: .zero)

    if let sample = audioFirstSample, let (_, audioInput) = audioPair {
        if !audioInput.append(sample) {
            logStderr("[lpimport] warn: 音频首帧写入失败，结果可能没有声音")
        }
    }

    if let adaptor = metadataAdaptor {
        let item = AVMutableMetadataItem()
        item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.value = 0 as NSNumber
        item.dataType = "com.apple.metadata.datatype.int8"
        let range = CMTimeRange(
            start: CMTime(seconds: stillTime, preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: 600)
        )
        if !adaptor.append(AVTimedMetadataGroup(items: [item], timeRange: range)) {
            logStderr("[lpimport] warn: 追加 still-image-time 样本失败")
        }
        metadataAdaptor = nil
    }

    // 逐轨搬运样本（非实时，简单轮询）
    var pending: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
    if let audioPair = audioPair {
        pending.append(audioPair)
    }
    var waitRounds = 0
    while !pending.isEmpty {
        var progressed = false
        var waiting = false
        var index = pending.count - 1
        while index >= 0 {
            let (output, input) = pending[index]
            if input.isReadyForMoreMediaData {
                if let sample = output.copyNextSampleBuffer() {
                    if !input.append(sample) {
                        throw writer.error ?? NSError(domain: "lpimport", code: 25, userInfo: [
                            NSLocalizedDescriptionKey: "写入样本失败（track=\(input.mediaType.rawValue)）"
                        ])
                    }
                    progressed = true
                } else {
                    input.markAsFinished()
                    pending.remove(at: index)
                    progressed = true
                }
            } else {
                waiting = true
            }
            index -= 1
        }
        if !progressed && waiting {
            usleep(2000)
            waitRounds += 1
            if waitRounds > 30000 {
                throw NSError(domain: "lpimport", code: 26, userInfo: [
                    NSLocalizedDescriptionKey: "重写视频超时"
                ])
            }
        }
    }

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()

    guard writer.status == .completed else {
        throw writer.error ?? NSError(domain: "lpimport", code: 27, userInfo: [
            NSLocalizedDescriptionKey: "AVAssetWriter 结束失败 status=\(writer.status.rawValue)"
        ])
    }

    // 自检：确认输出里真的有 metadata 轨和 content.identifier
    let written = AVURLAsset(url: output)
    let types = written.tracks.map { $0.mediaType.rawValue }
    logStderr("[lpimport] 重写后轨道：\(types.joined(separator: ","))（共 \(types.count) 条）")
    let metaKeys = written.metadata.compactMap { $0.key as? String }
    if !metaKeys.contains("com.apple.quicktime.content.identifier") {
        logStderr("[lpimport] warn: 重写后的视频没有 content.identifier，元数据键=\(metaKeys.joined(separator: ","))")
    }
}

// MARK: - 主流程

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

guard let imagePath = options.image, let videoPath = options.video else {
    fail("必须同时提供 --image 与 --video", code: 2)
}

let imageURL = URL(fileURLWithPath: imagePath)
let videoURL = URL(fileURLWithPath: videoPath)
for url in [imageURL, videoURL] where !FileManager.default.fileExists(atPath: url.path) {
    fail("文件不存在: \(url.path)", code: 2)
}

let status = requestPhotosAccess()
guard status == .authorized else {
    fail("照片图库权限未授予 (status=\(status.rawValue))，请在 系统设置 > 隐私与安全性 > 照片 中允许 lpimport / Terminal", code: 3)
}

// 需要与视频里同样的 asset identifier 才能让 Photos 认这对资源
var stillURL = imageURL
var taggedStillURL: URL?
if let identifier = options.identifier, !identifier.isEmpty {
    let output = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lpimport-\(identifier).jpg")
    do {
        try writeTaggedStill(from: imageURL, to: output, identifier: identifier, maxPixel: options.maxPixel)
    } catch {
        fail("给静止帧写入 Live Photo 标识失败: \(error.localizedDescription)")
    }
    stillURL = output
    taggedStillURL = output
    logStderr("[lpimport] 已给静止帧写入标识 \(identifier) → \(output.lastPathComponent)")
}

if options.dump {
    dumpImageProperties("input", imageURL)
    dumpImageProperties("tagged", stillURL)
}

// 用 AVAssetWriter 重写视频：补出 still-image-time 轨（ffmpeg 做不到）
var videoURLToUse = videoURL
var composedMovieURL: URL?
if let identifier = options.identifier, !identifier.isEmpty, options.compose {
    let output = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lpimport-\(identifier).mov")
    do {
        try rewriteMovie(input: videoURL, output: output, identifier: identifier)
    } catch {
        fail("重写视频（补 still-image-time 轨）失败: \(error.localizedDescription)")
    }
    videoURLToUse = output
    composedMovieURL = output
    logStderr("[lpimport] 已重写视频（content.identifier + still-image-time 轨）→ \(output.lastPathComponent)")
}

var placeholderIdentifier: String?
var importError: Error?
let importSemaphore = DispatchSemaphore(value: 0)

PHPhotoLibrary.shared().performChanges({
    let request = PHAssetCreationRequest.forAsset()

    let photoOptions = PHAssetResourceCreationOptions()
    photoOptions.originalFilename = stillURL.lastPathComponent
    request.addResource(with: .photo, fileURL: stillURL, options: photoOptions)

    let videoOptions = PHAssetResourceCreationOptions()
    videoOptions.originalFilename = videoURLToUse.lastPathComponent
    request.addResource(with: .pairedVideo, fileURL: videoURLToUse, options: videoOptions)

    if let date = options.date {
        request.creationDate = date
    }

    placeholderIdentifier = request.placeholderForCreatedAsset?.localIdentifier
}, completionHandler: { success, error in
    if !success || placeholderIdentifier == nil {
        importError = error ?? NSError(domain: "lpimport", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Photos 拒绝了该 Live Photo（通常是视频超过 3 秒、编码不受支持或宽高比差异过大）"
        ])
    }
    importSemaphore.signal()
})

importSemaphore.wait()

if let error = importError {
    let ns = error as NSError
    var detail = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    if ns.domain == "PHPhotosErrorDomain" && ns.code == 3302 {
        let hints = [
            "",
            "[提示] PHPhotosError 3302 = Photos 不接受这对资源。排查顺序：",
            "  1. 静止帧的 Apple MakerNote tag 17 必须与视频的 content.identifier 一致",
            "     （worker 默认会传 --identifier 并写入视频；设了 PAIR_IDENTIFIER=0 就会不一致）",
            "  2. 尺寸/比例差异过大 → MATCH_STILL_TO_VIDEO=1",
            "  3. 时长/编码不达标 → TRIM_SECONDS=2.9，确认是 H.264 + yuv420p",
        ]
        detail += "\n" + hints.joined(separator: "\n")
    }
    fail("合成 Live Photo 失败: \(detail)")
}

guard let assetIdentifier = placeholderIdentifier else {
    fail("未获得 asset identifier")
}

var albumValue: Any = NSNull()
if let albumName = options.album, !albumName.isEmpty {
    var albumIdentifier = findAlbumIdentifier(named: albumName)
    if albumIdentifier == nil {
        albumIdentifier = createAlbum(named: albumName)
    }
    if let albumIdentifier = albumIdentifier {
        addAsset(assetIdentifier, toAlbum: albumIdentifier)
        albumValue = albumName
    }
}

var taggedValue: Any = NSNull()
if let taggedStillURL = taggedStillURL {
    taggedValue = taggedStillURL.path
    try? FileManager.default.removeItem(at: taggedStillURL)
}

var composedValue: Any = NSNull()
if let composedMovieURL = composedMovieURL {
    composedValue = composedMovieURL.path
    try? FileManager.default.removeItem(at: composedMovieURL)
}

var identifierValue: Any = NSNull()
if let identifier = options.identifier, !identifier.isEmpty {
    identifierValue = identifier
}

emit([
    "ok": true,
    "localIdentifier": assetIdentifier,
    "album": albumValue,
    "image": imageURL.path,
    "video": videoURL.path,
    "taggedStill": taggedValue,
    "composedVideo": composedValue,
    "identifier": identifierValue,
])

