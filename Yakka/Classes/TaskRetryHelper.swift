//
//  TaskRetryHelper.swift
//  Pods
//
//  Created by Kieran Harper on 29/1/17.
//
//

import UIKit

public class TaskRetryHelper {
    
    public let waitTimeline: [TimeInterval]
    public var maxNumRetries: Int {
        return waitTimeline.count
    }
    public private(set) var availableNumRetries: Int
    
    public init(waitTimeline: [TimeInterval]) {
        self.waitTimeline = waitTimeline
        self.availableNumRetries = waitTimeline.count
    }
    
    // Perform a time delayed retry if one is still available, otherwise perform some give-up code
    public func retryOrNah(queue: DispatchQueue = DispatchQueue.main, retry: @escaping ()->(), nah: @escaping ()->()) {
        
        if availableNumRetries > 0 {
            let wait = waitTimeline[maxNumRetries - availableNumRetries]
            availableNumRetries = availableNumRetries - 1
            queue.asyncAfter(deadline: .now() + wait) {
                retry()
            }
        } else {
            queue.async {
                nah()
            }
        }
    }
    
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
