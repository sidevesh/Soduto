//
//  FileManager.swift
//  Soduto
//
//  Created by Giedrius on 2017-04-05.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import os

extension FileManager {
    
    /// Soduto's own cache folder, `~/Library/Application Support/<bundle id>/Cache/<name>`, created on demand.
    ///
    /// Deliberately not `~/Library/Caches`: macOS's cache cleaner (CacheDelete) *kills* a running sandboxed
    /// app to empty its container's Caches folder when it wants disk space ("CacheDeleteAppContainerCaches
    /// requesting termination assertion"), which made Soduto vanish from the menu bar. Callers trim what
    /// they store here themselves (album art ages out, SMS attachments are cleared at launch).
    public func sodutoCacheDirectory(_ name: String) -> URL? {
        guard let support = try? url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let directory = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.soduto.Soduto", isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    /// Empties the app's `~/Library/Caches` (inside its container) so CacheDelete has nothing to purge and
    /// no reason to terminate Soduto. Call once at launch, before anything writes there.
    public func clearPurgeableCaches() {
        guard let caches = try? url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let items = try? contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for item in items where (try? removeItem(at: item)) != nil {
            removed += 1
        }
        if removed > 0 {
            Logger.general.notice("Cleared \(removed, privacy: .public) item(s) from Library/Caches so macOS won't quit Soduto to purge them")
        }
    }
    
    public var compatTemporaryDirectory: URL {
        if #available(OSX 10.12, *) {
            return temporaryDirectory
        }
        else {
            return (try? url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
    }
    
}
