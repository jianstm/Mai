//
//  VideoManager.swift
//  Mai
//
//  Created by Quentin Jin on 2018/10/27.
//  Copyright © 2018 v2ambition. All rights reserved.
//

import Foundation
import RxSwift
import Alamofire
import RxAlamofire
import SwiftyJSON
import FileKit
import Cocoa
import Reachability
import RxReachability

final class VideoManager {

    private enum K {
        static let cacheSizeLimit = 100 * (1 << 20)  // 100 MB

        static let id = "com.v2ambition.mai"
        static let cachePath = Path.userMovies + "Mai" + ".cache"
        static let likePath = Path.userMovies + "Mai" + "like"
        static let dislikePath = Path.userMovies + "Mai" + ".dislike"

        static let apiHost = "animeloop.org"
        static let baseURL = "https://animeloop.org/api/v2"

        static let ascending = { (lhs: Path, rhs: Path) -> Bool in
            guard let ld = lhs.creationDate, let rd = rhs.creationDate else { return true }
            return ld < rd
        }
    }

    private let ioQueue = DispatchQueue(label: UUID().uuidString)
    private let disposeBag = DisposeBag()
    private let reachability = Reachability(hostname: K.apiHost)
    private var fetchDisposable: Disposable?

    private init() {
        createDirIfNeeded()
        copyDefaultVideo()
        cleanCacheDirIfNeede()

        reachability?.rx
            .status
            .distinctUntilChanged()
            .bind { [weak self] c in
                Logger.debug("API reachability changed,", "connection: \(c)")
                if c == .none {
                    Logger.warn("API is unreachable, Stop fetching new videos")
                    self?.fetchDisposable?.dispose()
                } else {
                    Logger.info("API is reachable, Start to fetch a new video")
                    self?.fetch()
                }
            }
            .disposed(by: disposeBag)
    }

    static let shared = VideoManager()

    private func createDirIfNeeded() {
        for p in [K.cachePath, K.likePath, K.dislikePath] {
            if !p.exists {
                do {
                    try p.createDirectory()
                } catch let err {
                    Logger.error("Failed to create directory", p, err)
                }
            }
        }
    }

    private func copyDefaultVideo() {
        if let path = Bundle.main.path(forResource: "5bbadd3466e1f3205b7e4e98", ofType: "mp4") {
            let video = Path(path)
            do {
                try video.moveFile(to: K.cachePath + video.fileName)
            } catch let err {
                Logger.error("Failed to copy default video", err)
            }
        }
    }

    private func cleanCacheDirIfNeede() {
        ioQueue.async {
            var totalSize = K.cachePath.children().reduce(into: 0, { $0 += ($1.fileSize ?? 0) })
            var files = K.cachePath.children()
                .filter {
                    $0.pathExtension == "mp4"
                }
                .sorted(by: K.ascending)
                .reversed()
                .map({ $0 })

            var deleted: [Path] = []
            while totalSize > (K.cacheSizeLimit / 3 * 2) {
                guard let path = files.popLast() else {
                    Logger.error("No file???")
                    preconditionFailure("No file???")
                }
                do {
                    guard let fileSize = path.fileSize else { continue }
                    totalSize -= fileSize
                    try path.deleteFile()
                    deleted.append(path)
                } catch let err {
                    Logger.error("Failed to delete file", path, err)
                }
            }

            if !deleted.isEmpty {
                Logger.cheer("Cache dir has been cleaned", deleted)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.cleanCacheDirIfNeede()
            }
        }
    }

    var allCachedVideo: [URL] {
        return ioQueue.sync {
            return K.cachePath
                .children()
                .filter({ $0.pathExtension == "mp4" })
                .sorted(by: K.ascending)
                .reversed()
                .map({ $0.url })
        }
    }

    var allLikedVideos: [URL] {
        return ioQueue.sync {
            return K.likePath
                .children()
                .filter({ $0.pathExtension == "mp4" })
                .sorted(by: K.ascending)
                .reversed()
                .map({ $0.url })
        }
    }

    func like(_ url: URL) {
        ioQueue.sync {
            if let path = Path(url: url) {
                let dest = K.likePath + path.fileName
                guard !dest.exists else { return }
                do {
                    Logger.info("Copy the video to like path", dest)
                    try path.copyFile(to: dest)
                } catch let err {
                    Logger.error("Failed to move file to like dir", dest, err)
                }
            }
        }
    }

    func dislike(_ url: URL) {
        ioQueue.sync {
            if let path = Path(url: url), path.exists {
                let dest = K.dislikePath + path.fileName
                do {
                    Logger.info("Move the video to dislike path", dest)
                    try path.moveFile(to: dest)
                } catch let err {
                    Logger.error("Failed to move file to dislike dir", dest, err)
                }
            }
        }
    }

    func fetchIfPossible() {
        try? reachability?.startNotifier()
    }

    private func fetch() {

        Logger.debug("Fetching...")
        fetchDisposable = RxAlamofire
            .json(.get,
                  K.baseURL + "/rand/loop",
                  parameters: ["full": true, "limit": 1]
            )
            .flatMap { (obj) -> Observable<(String, Data)> in
                if let url = JSON(obj)["data"][0]["files"]["mp4_1080p"].string {
                    return RxAlamofire.data(.get, url).map { (url, $0) }
                }
                return Observable.empty()
            }
            .subscribe(onNext: { [weak self] (url, data) in
                let fileName = Path(url).fileName
                let dest = K.cachePath + fileName
                do {
                    try self?.ioQueue.sync {
                        try data.write(to: dest)
                    }
                    EventBus.newVideo.accept(dest.url)
                    Logger.cheer("A new video has been downloaded and written to disk", fileName)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        self?.fetch()
                    }
                } catch let err {
                    Logger.error("Failed to write video to disk", dest, err)
                }
            }, onError: { [weak self] (err) in
                Logger.error("Failed to download video", err)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.fetch()
                }
            })
    }

    func stopTryingFetching() {
        fetchDisposable?.dispose()
        reachability?.stopNotifier()
    }
}
