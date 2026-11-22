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
//  用法：lpimport --image a.jpg --video a.mov [--album "小红书Live"] [--date 2024-09-04T20:53:34Z] [--quiet]
//
//  注意：本文件是 swiftc 单文件可执行入口，顶层代码就是 main，请勿改动文件顺序。
//

import Foundation
import Photos

struct Options {
    var image: String?
    var video: String?
    var album: String?
    var date: Date?
    var quiet = false
}

let usageLines = [
    "usage: lpimport --image <still.jpg> --video <live.mov> [options]",
    "",
    "  --image, -i  静止帧图片（JPEG/HEIC）",
    "  --video, -v  配对视频（H.264 .mov/.mp4，建议 3 秒）",
    "  --album, -a  导入后加入（必要时创建）的相簿名",
    "  --date       照片拍摄时间，ISO8601，如 2024-09-04T20:53:34Z",
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

var placeholderIdentifier: String?
var importError: Error?
let importSemaphore = DispatchSemaphore(value: 0)

PHPhotoLibrary.shared().performChanges({
    let request = PHAssetCreationRequest.forAsset()

    let photoOptions = PHAssetResourceCreationOptions()
    photoOptions.originalFilename = imageURL.lastPathComponent
    request.addResource(with: .photo, fileURL: imageURL, options: photoOptions)

    let videoOptions = PHAssetResourceCreationOptions()
    videoOptions.originalFilename = videoURL.lastPathComponent
    request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)

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
    fail("合成 Live Photo 失败: \(error.localizedDescription)")
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

emit([
    "ok": true,
    "localIdentifier": assetIdentifier,
    "album": albumValue,
    "image": imageURL.path,
    "video": videoURL.path,
])

