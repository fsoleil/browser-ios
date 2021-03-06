/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import WebKit
import Shared

/*
 module.exports.categories = {
 BOOKMARKS: '0',
 HISTORY_SITES: '1',
 PREFERENCES: '2'
 }

 module.exports.actions = {
 CREATE: 0,
 UPDATE: 1,
 DELETE: 2
 }
 */

let NotificationSyncReady = "NotificationSyncReady"

enum SyncRecordType : String {
    case bookmark = "BOOKMARKS"
    case history = "HISTORY_SITES"
    case prefs = "PREFERENCES"
}

enum SyncActions: Int {
    case create = 0
    case update = 1
    case delete = 2

}

class Sync: JSInjector {
    
    static let SeedByteLength = 32
    /// Number of records that is considered a fetch limit as opposed to full data set
    static let RecordRateLimitCount = 985
    static let shared = Sync()

    /// This must be public so it can be added into the view hierarchy 
    var webView: WKWebView!

    // Should not be accessed directly
    private var syncReadyLock = false
    var isSyncFullyInitialized = (syncReady: Bool, fetchReady: Bool, sendRecordsReady: Bool, resolveRecordsReady: Bool, deleteUserReady: Bool, deleteSiteSettingsReady: Bool, deleteCategoryReady: Bool)(false, false, false, false, false, false, false)
    
    var isInSyncGroup: Bool {
        return syncSeed != nil
    }
    
    private var fetchTimer: NSTimer?

    // TODO: Move to a better place
    private let prefNameId = "device-id-js-array"
    private let prefNameSeed = "seed-js-array"
    private let prefFetchTimestamp = "sync-fetch-timestamp"
    
//    #if DEBUG
//    private let isDebug = true
//    private let serverUrl = "https://sync-staging.brave.com"
//    #else
    private let isDebug = false
    private let serverUrl = "https://sync.brave.com"
//    #endif

    private let apiVersion = 0

    private var webConfig:WKWebViewConfiguration {
        let webCfg = WKWebViewConfiguration()
        let userController = WKUserContentController()

        userController.addScriptMessageHandler(self, name: "syncToIOS_on")
        userController.addScriptMessageHandler(self, name: "syncToIOS_send")

        // ios-sync must be called before bundle, since it auto-runs
        ["fetch", "ios-sync", "bundle"].forEach() {
            userController.addUserScript(WKUserScript(source: Sync.getScript($0), injectionTime: .AtDocumentEnd, forMainFrameOnly: true))
        }

        webCfg.userContentController = userController
        return webCfg
    }
    
    override init() {
        super.init()
        
        // TODO: Remove - currently for sync testing
//        syncSeed = nil
        
        self.isJavascriptReadyCheck = checkIsSyncReady
        self.maximumDelayAttempts = 15
        self.delayLengthInSeconds = Int64(3.0)
        
        webView = WKWebView(frame: CGRectMake(30, 30, 300, 500), configuration: webConfig)
        // Attempt sync setup
        initializeSync()
    }
    
    func leaveSyncGroup() {
        syncSeed = nil
        // TODO: Send network removal
    }
    
    /// Sets up sync to actually start pulling/pushing data. This method can only be called once
    /// seed (optional): The user seed, in the form of string hex values. Must be even number : ["00", "ee", "4a", "42"]
    /// Notice:: seed will be ignored if the keychain already has one, a user must disconnect from existing sync group prior to joining a new one
    func initializeSync(seed: [Int]? = nil) {
        
        // TODO: use consant for 16
        if let joinedSeed = seed where joinedSeed.count == Sync.SeedByteLength {
            // Always attempt seed write, setter prevents bad overwrites
            syncSeed = "\(joinedSeed)"
        }
        
        // Autoload sync if already connected to a sync group, otherwise just wait for user initiation
        if let _ = syncSeed {
            self.webView.loadHTMLString("<body>TEST</body>", baseURL: nil)
        }
    }
    
    func initializeNewSyncGroup() {
        if syncSeed != nil {
            // Error, to setup new sync group, must have no seed
            return
        }
        
        self.webView.loadHTMLString("<body>TEST</body>", baseURL: nil)
    }

    class func getScript(name:String) -> String {
        // TODO: Add unwrapping warnings
        // TODO: Place in helper location
        let filePath = NSBundle.mainBundle().pathForResource(name, ofType:"js")
        return try! String(contentsOfFile: filePath!, encoding: NSUTF8StringEncoding)
    }

    private func webView(webView: WKWebView, didFinish navigation: WKNavigation!) {
        print(#function)
    }

    private var syncDeviceId: [Int]? {
        get {
            let deviceId = NSUserDefaults.standardUserDefaults().valueForKey(prefNameId)
            if let id = deviceId as? Int {
                return [id]
            }
            return nil
        }
        set(value) {
            NSUserDefaults.standardUserDefaults().setValue(value?.first ?? nil, forKey: prefNameId)
            NSUserDefaults.standardUserDefaults().synchronize()
        }
    }

    // TODO: Move to keychain
    private var syncSeed: String? {
        get {
            return NSUserDefaults.standardUserDefaults().stringForKey(prefNameSeed)
        }
        set(value) {
            // TODO: Move syncSeed validation here, remove elsewhere
            
            if isInSyncGroup && value != nil {
                // Error, cannot replace sync seed with another seed
                //  must set syncSeed to nil prior to replacing it
                return
            }
            
            if value == nil {
                // Clean up group specific items
                syncDeviceId = nil
                lastFetchedRecordTimestamp = 0
                lastSuccessfulSync = 0
                syncReadyLock = false
                isSyncFullyInitialized = (false, false, false, false, false, false, false)
                
                fetchTimer?.invalidate()
                fetchTimer = nil
            }
            
            NSUserDefaults.standardUserDefaults().setObject(value, forKey: prefNameSeed)
            NSUserDefaults.standardUserDefaults().synchronize()
        }
    }
    
    var syncSeedArray: [Int]? {
        let splitBytes = syncSeed?.componentsSeparatedByCharactersInSet(NSCharacterSet(charactersInString: "[], ")).filter { !$0.isEmpty }
        let seed = splitBytes?.map{ Int($0) }.flatMap{ $0 }
        return seed?.count == Sync.SeedByteLength ? seed : nil
    }
    
    // This includes just the last record that was fetched, used to store timestamp until full process has been completed
    //  then set into defaults
    private var lastFetchedRecordTimestamp: Int? = 0
    // This includes the entire process: fetching, resolving, insertion/update, and save
    private var lastSuccessfulSync: Int {
        get {
            return NSUserDefaults.standardUserDefaults().integerForKey(prefFetchTimestamp)
        }
        set(value) {
            NSUserDefaults.standardUserDefaults().setInteger(value, forKey: prefFetchTimestamp)
            NSUserDefaults.standardUserDefaults().synchronize()
        }
    }

    func checkIsSyncReady() -> Bool {
        
        if syncReadyLock {
            return true
        }

        let mirror = Mirror(reflecting: isSyncFullyInitialized)
        let ready = mirror.children.reduce(true) { $0 && $1.1 as! Bool }
        if ready {
            syncReadyLock = true
            NSNotificationCenter.defaultCenter().postNotificationName(NotificationSyncReady, object: nil)
            
            func startFetching() {
                // Perform first fetch manually
                self.fetch()
                
                // Fetch timer to run on regular basis
                fetchTimer = NSTimer.scheduledTimerWithTimeInterval(30.0, target: self, selector: #selector(Sync.fetchWrapper), userInfo: nil, repeats: true)
            }
            
            if lastFetchedRecordTimestamp == 0 {
                // Sync local bookmarks, then proceed with fetching
                // Pull all local bookmarks
                self.sendSyncRecords(.bookmark, action: .create, bookmarks: Bookmark.getAllBookmarks()) { error in
                    startFetching()
                }
            } else {
                startFetching()
            }
        }
        return ready
    }
    
    // Required since fetch is wrapped in extension and timer hates that.
    // This can be removed and fetch called directly via scheduledTimerBlock
    func fetchWrapper() {
        self.fetch()
    }
 }

// MARK: Native-initiated Message category
extension Sync {
    // TODO: Rename
    func sendSyncRecords(recordType: SyncRecordType, action: SyncActions, bookmarks: [Bookmark], completion: (NSError? -> Void)? = nil) {
        
        if bookmarks.isEmpty {
            completion?(nil)
            return
        }
        
        if !isInSyncGroup {
            completion?(nil)
            return
        }
        
        executeBlockOnReady() {
            
            let syncRecords = bookmarks.map {
                SyncRoot(bookmark: $0, deviceId: self.syncDeviceId, action: action.rawValue).dictionaryRepresentation()
            }
            
            guard let json = NSJSONSerialization.jsObject(withNative: syncRecords, escaped: false) else {
                // Huge error
                return
            }

            /* browser -> webview, sends this to the webview with the data that needs to be synced to the sync server.
             @param {string} categoryName, @param {Array.<Object>} records */
            let evaluate = "callbackList['send-sync-records'](null, 'BOOKMARKS',\(json))"
            self.webView.evaluateJavaScript(evaluate,
                                       completionHandler: { (result, error) in
                                        if error != nil {
                                            print(error)
                                        }
                                        
                                        completion?(error)
            })
        }
    }

    func gotInitData() {
        let deviceId = syncDeviceId?.description ?? "null"
        let syncSeed = isInSyncGroup ? "new Uint8Array(\(self.syncSeed!))" : "null"
        
        let args = "(null, \(syncSeed), \(deviceId), {apiVersion: '\(apiVersion)', serverUrl: '\(serverUrl)', debug:\(isDebug)})"
        print(args)
        webView.evaluateJavaScript("callbackList['got-init-data']\(args)",
                                   completionHandler: { (result, error) in
//                                    print(result)
//                                    if error != nil {
//                                        print(error)
//                                    }
        })
    }
    
    /// Makes call to sync to fetch new records, instead of just returning records, sync sends `get-existing-objects` message
    func fetch(completion: (NSError? -> Void)? = nil) {
        /*  browser -> webview: sent to fetch sync records after a given start time from the sync server.
         @param Array.<string> categoryNames, @param {number} startAt (in seconds) **/
        
        executeBlockOnReady() {
            
            // Pass in `lastFetch` to get records since that time
            self.webView.evaluateJavaScript("callbackList['fetch-sync-records'](null, ['BOOKMARKS'], \(self.lastSuccessfulSync), true)",
                                       completionHandler: { (result, error) in
                                        completion?(error)
            })
        }
    }

    func resolvedSyncRecords(data: [SyncRoot]?) {
        guard let syncRecords = data else { return }
        
        for fetchedRoot in syncRecords {
            if fetchedRoot.objectData != "bookmark" { return }
            
            guard
                let fetchedId = fetchedRoot.objectId
                else { return }
            
            let singleBookmark = Bookmark.get(syncUUIDs: [fetchedId])?.first
            
            let action = SyncActions.init(rawValue: fetchedRoot.action ?? -1)
            if action == SyncActions.delete {
                // TODO: Remove check and just let delete handle this
                guard let singleBookmark = singleBookmark else {
                    // Record already exists
                    return
                }
                
                // Remove record
                print("Deleting record!")
                Bookmark.remove(bookmark: singleBookmark)
                continue
            } else if action == SyncActions.create {
                
                if singleBookmark != nil {
                    // Error! Should not exist and call create
                }
                    
                // TODO: Needs favicon
                // TODO: Create better `add` method to accept sync bookmark
                Bookmark.add(rootObject: fetchedRoot, save: false)
            } else if action == SyncActions.update {
                singleBookmark?.update(rootObject: fetchedRoot, save: false)
            }
        }
        
        DataController.saveContext()
        print("\(syncRecords.count) records processed")
        
        // After records have been written, without crash, save timestamp
        if let stamp = self.lastFetchedRecordTimestamp { self.lastSuccessfulSync = stamp }
        
        if syncRecords.count > Sync.RecordRateLimitCount {
            // Do fast refresh, do not wait for timer
            self.fetch()
        }
    }

    func deleteSyncUser(data: [String: AnyObject]) {
        print("not implemented: deleteSyncUser() \(data)")
    }

    func deleteSyncCategory(data: [String: AnyObject]) {
        print("not implemented: deleteSyncCategory() \(data)")
    }

    func deleteSyncSiteSettings(data: [String: AnyObject]) {
        print("not implemented: delete sync site settings \(data)")
    }

}

// MARK: Server To Native Message category
extension Sync {

    func getExistingObjects(data: SyncResponse?) {
        //  as? [[String: AnyObject]]
        guard let syncRecords = data?.rootElements else { return }
        
        /* Top level keys: "bookmark", "action","objectId", "objectData:bookmark","deviceId" */
        
        // Root "AnyObject" here should either be [String:AnyObject] or the string literal "null"
        var matchedBookmarks = [[AnyObject]]()
        
        for fetchedBookmark in syncRecords {
            guard let fetchedId = fetchedBookmark.objectId else {
                continue
            }
            
            // TODO: Updated `get` method to accept only one record
            // Pulls bookmarks individually from CD to verify duplicates do not get added
            let bookmarks = Bookmark.get(syncUUIDs: [fetchedId])
            
            // TODO: Validate count, should never be more than one!

            var localSide: AnyObject = "null"
            if let bm = bookmarks?.first {
                localSide = bm.asDictionary(deviceId: syncDeviceId, action: fetchedBookmark.action)
            }
            
            matchedBookmarks.append([fetchedBookmark.dictionaryRepresentation(), localSide])
        }
        
        
        // TODO: Check if parsing not required
        guard let serializedData = NSJSONSerialization.jsObject(withNative: matchedBookmarks, escaped: false) else {
            // Huge error
            return
        }
        
        // Store the last record's timestamp, to know what timestamp to pass in next time if this one does not fail
        self.lastFetchedRecordTimestamp = data?.lastFetchedTimestamp
            
        self.webView.evaluateJavaScript("callbackList['resolve-sync-records'](null, ['BOOKMARKS'], \(serializedData))",
            completionHandler: { (result, error) in })
    }

    // Only called when the server has info for client to save
    func saveInitData(data: JSON) {
        // Sync Seed
        if let seedJSON = data["arg1"].asArray {
            let seed = seedJSON.map({ $0.asInt }).flatMap({ $0 })
            
            // TODO: Move to constant
            if seed.count < Sync.SeedByteLength {
                // Error
                return
            }
            
            syncSeed = "\(seed)"

        } else if syncSeed == nil {
            // Failure
            print("Seed expected.")
        }
        
        // Device Id
        if let deviceArray = data["arg2"].asArray where deviceArray.count > 0 {
            // TODO: Just don't set, if bad, allow sync to recover on next init
            syncDeviceId = deviceArray.map { $0.asInt ?? 0 }
        } else if syncDeviceId == nil {
            print("Device Id expected!")
        }

    }

}

extension Sync: WKScriptMessageHandler {
    func userContentController(userContentController: WKUserContentController, didReceiveScriptMessage message: WKScriptMessage) {
        //print("😎 \(message.name) \(message.body)")
        
        let syncResponse = SyncResponse(object: message.body)
        guard let messageName = syncResponse.message else {
            assert(false)
            return
        }

        switch messageName {
        case "get-init-data":
//            getInitData()
            break
        case "got-init-data":
            gotInitData()
        case "save-init-data" :
            // A bit hacky, but this method's data is not very uniform
            // (e.g. arg2 is [Int])
            let data = JSON(string: message.body as? String ?? "")
            saveInitData(data)
        case "get-existing-objects":
            getExistingObjects(syncResponse)
        case "resolved-sync-records":
            resolvedSyncRecords(syncResponse.rootElements)
        case "sync-debug":
            let data = JSON(string: message.body as? String ?? "")
            print("---- Sync Debug: \(data)")
        case "sync-ready":
            isSyncFullyInitialized.syncReady = true
        case "fetch-sync-records":
            isSyncFullyInitialized.fetchReady = true
        case "send-sync-records":
            isSyncFullyInitialized.sendRecordsReady = true
        case "resolve-sync-records":
            isSyncFullyInitialized.resolveRecordsReady = true
        case "delete-sync-user":
            isSyncFullyInitialized.deleteUserReady = true
        case "delete-sync-site-settings":
            isSyncFullyInitialized.deleteSiteSettingsReady = true
        case "delete-sync-category":
            isSyncFullyInitialized.deleteCategoryReady = true
        default:
            print("\(messageName) not handled yet")
        }

        checkIsSyncReady()
    }
}

