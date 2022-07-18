//
//  NCAutoUpload.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 27/01/21.
//  Copyright © 2021 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import CoreLocation
import NCCommunication
import Photos

class NCAutoUpload: NSObject {
    @objc static let shared: NCAutoUpload = {
        let instance = NCAutoUpload()
        return instance
    }()

    private let appDelegate = UIApplication.shared.delegate as! AppDelegate
    private var endForAssetToUpload: Bool = false

    // MARK: -

    @objc func initAutoUpload(viewController: UIViewController?, completion: @escaping (_ items: Int) -> Void) {
        guard let activeAccount = NCManageDatabase.shared.getActiveAccount(), activeAccount.autoUpload else {
            completion(0)
            return
        }

        NCAskAuthorization.shared.askAuthorizationPhotoLibrary(viewController: viewController) { hasPermission in
            guard hasPermission else {
                NCManageDatabase.shared.setAccountAutoUploadProperty("autoUpload", state: false)
                completion(0)
                return
            }

            self.uploadAssetsNewAndFull(viewController: viewController, selector: NCGlobal.shared.selectorUploadAutoUpload, log: "Init Auto Upload") { items in
                completion(items)
            }
        }
    }

    @objc func autoUploadFullPhotos(viewController: UIViewController?, log: String) {

        NCAskAuthorization.shared.askAuthorizationPhotoLibrary(viewController: appDelegate.window?.rootViewController) { hasPermission in
            guard hasPermission else { return }

            NCContentPresenter.shared.messageNotification("_attention_", description: "_create_full_upload_", delay: NCGlobal.shared.dismissAfterSecondLong, type: .info, errorCode: NCGlobal.shared.errorNoError, priority: .max)
            NCUtility.shared.startActivityIndicator(backgroundView: nil, blurEffect: true)
            self.uploadAssetsNewAndFull(viewController: viewController, selector: NCGlobal.shared.selectorUploadAutoUploadAll, log: log) { _ in
                NCUtility.shared.stopActivityIndicator()
            }
        }
    }

    private func uploadAssetsNewAndFull(viewController: UIViewController?, selector: String, log: String, completion: @escaping (_ items: Int) -> Void) {
        guard !appDelegate.account.isEmpty else {
            completion(0)
            return
        }
        guard let account = NCManageDatabase.shared.getAccount(predicate: NSPredicate(format: "account == %@", appDelegate.account)) else { return }

        DispatchQueue.global(qos: .background).async {

            let autoUploadPath = NCManageDatabase.shared.getAccountAutoUploadPath(urlBase: account.urlBase, account: account.account)
            var metadatas: [tableMetadata] = []

            self.getCameraRollAssets(viewController: viewController, account: account, selector: selector, alignPhotoLibrary: false) { assets in
                guard let assets = assets, !assets.isEmpty else {
                    NCCommunicationCommon.shared.writeLog("Automatic upload, no new assets found [" + log + "]")
                    completion(0)
                    return
                }
                NCCommunicationCommon.shared.writeLog("Automatic upload, new \(assets.count) assets found [" + log + "]")

                // Create the folder for auto upload & if request the subfolders
                if !NCNetworking.shared.createFolder(assets: assets, selector: selector, useSubFolder: account.autoUploadCreateSubfolder, account: account.account, urlBase: account.urlBase) {
                    if selector == NCGlobal.shared.selectorUploadAutoUploadAll {
                        NCContentPresenter.shared.messageNotification("_error_", description: "_error_createsubfolders_upload_", delay: NCGlobal.shared.dismissAfterSecond, type: .error, errorCode: NCGlobal.shared.errorInternalError, priority: .max)
                    }
                    return completion(0)
                }

                self.endForAssetToUpload = false

                for asset in assets {

                    var livePhoto = false
                    var session: String = ""
                    guard let assetDate = asset.creationDate else { continue }
                    let assetMediaType = asset.mediaType
                    var serverUrl: String = ""
                    let fileName = CCUtility.createFileName(asset.value(forKey: "filename") as? String, fileDate: assetDate, fileType: assetMediaType, keyFileName: NCGlobal.shared.keyFileNameAutoUploadMask, keyFileNameType: NCGlobal.shared.keyFileNameAutoUploadType, keyFileNameOriginal: NCGlobal.shared.keyFileNameOriginalAutoUpload, forcedNewFileName: false)!
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy"
                    let yearString = formatter.string(from: assetDate)
                    formatter.dateFormat = "MM"
                    let monthString = formatter.string(from: assetDate)

                    if asset.mediaSubtypes.contains(.photoLive) && CCUtility.getLivePhoto() {
                        livePhoto = true
                    }

                    if selector == NCGlobal.shared.selectorUploadAutoUploadAll {
                        session = NCCommunicationCommon.shared.sessionIdentifierUpload
                    } else {
                        if assetMediaType == PHAssetMediaType.image && account.autoUploadWWAnPhoto == false {
                            session = NCNetworking.shared.sessionIdentifierBackground
                        } else if assetMediaType == PHAssetMediaType.video && account.autoUploadWWAnVideo == false {
                            session = NCNetworking.shared.sessionIdentifierBackground
                        } else if assetMediaType == PHAssetMediaType.image && account.autoUploadWWAnPhoto {
                            session = NCNetworking.shared.sessionIdentifierBackgroundWWan
                        } else if assetMediaType == PHAssetMediaType.video && account.autoUploadWWAnVideo {
                            session = NCNetworking.shared.sessionIdentifierBackgroundWWan
                        } else { session = NCNetworking.shared.sessionIdentifierBackground }
                    }

                    if account.autoUploadCreateSubfolder {
                        serverUrl = autoUploadPath + "/" + yearString + "/" + monthString
                    } else {
                        serverUrl = autoUploadPath
                    }

                    // MOST COMPATIBLE SEARCH --> HEIC --> JPG
                    var fileNameSearchMetadata = fileName
                    let ext = (fileNameSearchMetadata as NSString).pathExtension.uppercased()
                    if ext == "HEIC" && CCUtility.getFormatCompatibility() {
                        fileNameSearchMetadata = (fileNameSearchMetadata as NSString).deletingPathExtension + ".jpg"
                    }
                    if NCManageDatabase.shared.getMetadata(predicate: NSPredicate(format: "account == %@ AND serverUrl == %@ AND fileNameView == %@", account.account, serverUrl, fileNameSearchMetadata)) != nil {
                        if selector == NCGlobal.shared.selectorUploadAutoUpload {
                            NCManageDatabase.shared.addPhotoLibrary([asset], account: account.account)
                        }
                    } else {
                        let metadata = NCManageDatabase.shared.createMetadata(account: account.account, user: account.user, userId: account.userId, fileName: fileName, fileNameView: fileName, ocId: NSUUID().uuidString, serverUrl: serverUrl, urlBase: account.urlBase, url: "", contentType: "", isLivePhoto: livePhoto)
                        metadata.assetLocalIdentifier = asset.localIdentifier
                        metadata.session = session
                        metadata.sessionSelector = selector
                        if selector == NCGlobal.shared.selectorUploadAutoUpload {
                            metadata.isAutoupload = true
                        }
                        metadata.status = NCGlobal.shared.metadataStatusWaitUpload
                        if assetMediaType == PHAssetMediaType.video {
                            metadata.classFile = NCCommunicationCommon.typeClassFile.video.rawValue
                        } else if assetMediaType == PHAssetMediaType.image {
                            metadata.classFile = NCCommunicationCommon.typeClassFile.image.rawValue
                        }
                        if selector == NCGlobal.shared.selectorUploadAutoUpload {
                            NCCommunicationCommon.shared.writeLog("Automatic upload added \(metadata.fileNameView) with Identifier \(metadata.assetLocalIdentifier)")
                            NCManageDatabase.shared.addPhotoLibrary([asset], account: account.account)
                        }
                        metadatas.append(metadata)
                    }
                }

                self.endForAssetToUpload = true
                if selector == NCGlobal.shared.selectorUploadAutoUploadAll {
                    self.appDelegate.networkingProcessUpload?.createProcessUploads(metadatas: metadatas)
                } else {
                    self.appDelegate.networkingProcessUpload?.createProcessUploads(metadatas: metadatas, verifyAlreadyExists: true)
                }
                completion(metadatas.count)
            }
        }
    }

    // MARK: -

    @objc func alignPhotoLibrary(viewController: UIViewController?) {
        guard let activeAccount = NCManageDatabase.shared.getActiveAccount() else { return }

        getCameraRollAssets(viewController: viewController, account: activeAccount, selector: NCGlobal.shared.selectorUploadAutoUploadAll, alignPhotoLibrary: true) { assets in
            NCManageDatabase.shared.clearTable(tablePhotoLibrary.self, account: activeAccount.account)
            guard let assets = assets else { return }

            NCManageDatabase.shared.addPhotoLibrary(assets, account: activeAccount.account)
            NCCommunicationCommon.shared.writeLog("Align Photo Library \(assets.count)")
        }
    }

    private func getCameraRollAssets(viewController: UIViewController?, account: tableAccount, selector: String, alignPhotoLibrary: Bool, completion: @escaping (_ assets: [PHAsset]?) -> Void) {

        NCAskAuthorization.shared.askAuthorizationPhotoLibrary(viewController: viewController) { hasPermission in
            guard hasPermission else {
                completion(nil)
                return
            }
            let assetCollection = PHAssetCollection.fetchAssetCollections(with: PHAssetCollectionType.smartAlbum, subtype: PHAssetCollectionSubtype.smartAlbumUserLibrary, options: nil)
            if assetCollection.count == 0 {
                completion(nil)
                return
            }

            let predicateImage = NSPredicate(format: "mediaType == %i", PHAssetMediaType.image.rawValue)
            let predicateVideo = NSPredicate(format: "mediaType == %i", PHAssetMediaType.video.rawValue)
            var predicate: NSPredicate?
            let fetchOptions = PHFetchOptions()
            var newAssets: [PHAsset] = []

            if alignPhotoLibrary || (account.autoUploadImage && account.autoUploadVideo) {
                predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [predicateImage, predicateVideo])
            } else if account.autoUploadImage {
                predicate = predicateImage
            } else if account.autoUploadVideo {
                predicate = predicateVideo
            } else {
                return completion(nil)
            }

            fetchOptions.predicate = predicate
            let assets: PHFetchResult<PHAsset> = PHAsset.fetchAssets(in: assetCollection.firstObject!, options: fetchOptions)

            if selector == NCGlobal.shared.selectorUploadAutoUpload {
                var creationDate = ""
                var idAsset = ""
                let idsAsset = NCManageDatabase.shared.getPhotoLibraryIdAsset(image: account.autoUploadImage, video: account.autoUploadVideo, account: account.account)
                assets.enumerateObjects { asset, _, _ in
                    if asset.creationDate != nil { creationDate = String(describing: asset.creationDate!) }
                    idAsset = account.account + asset.localIdentifier + creationDate
                    if !(idsAsset?.contains(idAsset) ?? false) {
                        newAssets.append(asset)
                    }
                }
            } else {
                assets.enumerateObjects { asset, _, _ in
                    newAssets.append(asset)
                }
            }
            completion(newAssets)
        }
    }
}
