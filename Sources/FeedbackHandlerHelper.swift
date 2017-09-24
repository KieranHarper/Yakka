//
//  FeedbackHandlerHelper.swift
//  Yakka
//
//  Created by Kieran Harper on 24/9/17.
//
//

import Foundation
import Dispatch

/// Grouping of a feedback handler and the queue it should run on
internal struct FeedbackHandlerHelper<T> {
    let queue: DispatchQueue?
    let handler: (T)->()
}

/// Helper to provide feedback via a series of handlers which take no parameters
internal func notifyHandlers(from helpers: [FeedbackHandlerHelper<Void>], defaultQueue: DispatchQueue) {
    let batches = getQueueBatches(from: helpers, defaultQueue: defaultQueue)
    for (queue, batch) in batches {
        queue.async {
            for handler in batch {
                handler(())
            }
        }
    }
}

/// Helper to provide feedback via a series of handlers which take a generic parameter
internal func notifyHandlers<T>(from helpers: [FeedbackHandlerHelper<T>], defaultQueue: DispatchQueue, parameters: T) {
    let batches = getQueueBatches(from: helpers, defaultQueue: defaultQueue)
    for (queue, batch) in batches {
        queue.async {
            for handler in batch {
                handler(parameters)
            }
        }
    }
}

private func getQueueBatches<T>(from helpers: [FeedbackHandlerHelper<T>], defaultQueue: DispatchQueue) -> [DispatchQueue: [(T)->()]] {
    var dict = [DispatchQueue: [(T)->()]]()
    for helper in helpers {
        let queue = helper.queue ?? defaultQueue
        if var bunch = dict[queue] {
            bunch.append(helper.handler)
            dict[queue] = bunch
        } else {
            let bunch = [helper.handler]
            dict[queue] = bunch
        }
    }
    return dict
}
