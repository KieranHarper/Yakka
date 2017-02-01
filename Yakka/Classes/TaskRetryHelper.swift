//
//  TaskRetryHelper.swift
//  Pods
//
//  Created by Kieran Harper on 29/1/17.
//
//

import Foundation

/// Helper class that provides a means to retry something up to a limit, and according to a wait schedule
public class TaskRetryHelper {
    
    
    
    // MARK: - Properties
    
    /// The timeline of inter-attempt wait durations that was provided on construction
    public let waitTimeline: [TimeInterval]
    
    /// The maximum number of retries this will allow
    public var maxNumRetries: Int {
        return waitTimeline.count
    }
    
    /// Number of remaining retry attempts before this will elect to fail instead
    public private(set) var remainingNumRetries: Int
    
    
    
    
    // MARK: - Instance methods
    
    /// Construct with a wait timeline to use, which defines which delay to use for each retry attempt and how many are allowed
    public init(waitTimeline: [TimeInterval]) {
        self.waitTimeline = waitTimeline
        self.remainingNumRetries = waitTimeline.count
    }
    
    /// Perform a time delayed retry if it hasn't maxxed them out already, otherwise perform some give-up code
    public func retryOrNah(onQueue queue: DispatchQueue = DispatchQueue.main, retry: @escaping ()->(), nah: @escaping ()->()) {
        
        if remainingNumRetries > 0 {
            let wait = waitTimeline[maxNumRetries - remainingNumRetries]
            remainingNumRetries = remainingNumRetries - 1
            queue.asyncAfter(deadline: .now() + wait) {
                retry()
            }
        } else {
            queue.async {
                nah()
            }
        }
    }
    
    
    
    
    // MARK: - Static helpers
    
    public class func exponentialBackoffTimeline(forMaxRetries maxRetries: Int, startingAt initialWait: TimeInterval) -> [TimeInterval] {
        var toReturn = Array<TimeInterval>()
        toReturn.append(max(initialWait, 0.0))
        for ii in 1..<maxRetries {
            var next = toReturn[ii - 1] * 2.0
            if next == 0.0 {
                next = 1.0
            }
            toReturn.append(next)
        }
        return toReturn
    }
}
