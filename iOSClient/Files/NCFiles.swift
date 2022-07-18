//
//  NCFiles.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 26/09/2020.
//  Copyright © 2020 Marino Faggiana. All rights reserved.
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
import NCCommunication

class NCFiles: NCCollectionViewCommon {

    internal var isRoot: Bool = true

    // MARK: - View Life Cycle

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        appDelegate.activeFiles = self
        titleCurrentFolder = NCBrandOptions.shared.brand
        layoutKey = NCGlobal.shared.layoutViewFiles
        enableSearchBar = true
        headerMenuButtonsCommand = true
        headerMenuButtonsView = true
        headerRichWorkspaceDisable = false
        emptyImage = UIImage(named: "folder")?.image(color: NCBrandColor.shared.brandElement, size: UIScreen.main.bounds.width)
        emptyTitle = "_files_no_files_"
        emptyDescription = "_no_file_pull_down_"
    }

    override func viewWillAppear(_ animated: Bool) {
        if isRoot {
            serverUrl = NCUtilityFileSystem.shared.getHomeServer(account: appDelegate.account)
            titleCurrentFolder = getNavigationTitle()
        }
        super.viewWillAppear(animated)
    }

    // MARK: - NotificationCenter

    override func initialize(_ notification: NSNotification) {
        if isRoot {
            serverUrl = NCUtilityFileSystem.shared.getHomeServer(account: appDelegate.account)
            titleCurrentFolder = getNavigationTitle()
        }
        super.initialize(notification)

        if let userInfo = notification.userInfo as NSDictionary?, userInfo["atStart"] as? Int == 1 {
            return
        }

        reloadDataSource(forced: false)
        reloadDataSourceNetwork()
    }

    // MARK: - DataSource + NC Endpoint
    //
    // forced: do no make the etag of directory test (default)
    //
    override func reloadDataSource(forced: Bool = true) {
        super.reloadDataSource()

        DispatchQueue.main.async { self.refreshControl.endRefreshing() }
        guard !isSearching, !appDelegate.account.isEmpty, !appDelegate.urlBase.isEmpty, !serverUrl.isEmpty else { return }

        let metadatas = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "account == %@ AND serverUrl == %@", appDelegate.account, serverUrl))
        if self.metadataFolder == nil {
            self.metadataFolder = NCManageDatabase.shared.getMetadataFolder(account: self.appDelegate.account, urlBase: appDelegate.urlBase, serverUrl: serverUrl)
        }
        let directory = NCManageDatabase.shared.getTableDirectory(predicate: NSPredicate(format: "account == %@ AND serverUrl == %@", appDelegate.account, serverUrl))

        // FORCED false: test the directory.etag
        if !forced, let directory = directory, directory.etag == dataSource.directory?.etag {
            return
        }

        dataSource = NCDataSource(
            metadatas: metadatas,
            account: self.appDelegate.account,
            directory: directory,
            sort: self.layoutForView?.sort,
            ascending: self.layoutForView?.ascending,
            directoryOnTop: self.layoutForView?.directoryOnTop,
            favoriteOnTop: true,
            filterLivePhoto: true,
            groupByField: self.groupByField,
            providers: self.providers,
            searchResults: self.searchResults)

        DispatchQueue.main.async { self.collectionView.reloadData() }
    }

    override func reloadDataSourceNetwork(forced: Bool = false) {
        super.reloadDataSourceNetwork(forced: forced)
        guard !isSearching else {
            networkSearch()
            return
        }
        isReloadDataSourceNetworkInProgress = true
        collectionView?.reloadData()

        networkReadFolder(forced: forced) { tableDirectory, metadatas, metadatasUpdate, metadatasDelete, errorCode, _ in
            if errorCode == 0 {
                for metadata in metadatas ?? [] {
                    if !metadata.directory, NCManageDatabase.shared.isDownloadMetadata(metadata, download: false) {
                        NCOperationQueue.shared.download(metadata: metadata, selector: NCGlobal.shared.selectorDownloadFile)
                    }
                }
            }

            self.isReloadDataSourceNetworkInProgress = false
            self.richWorkspaceText = tableDirectory?.richWorkspace

            if metadatasUpdate?.count ?? 0 > 0 || metadatasDelete?.count ?? 0 > 0 || forced {
                self.reloadDataSource(forced: false)
            } else if self.dataSource.getMetadataSourceForAllSections().isEmpty {
                DispatchQueue.main.async { self.collectionView.reloadData() }
            }
        }
    }
}
