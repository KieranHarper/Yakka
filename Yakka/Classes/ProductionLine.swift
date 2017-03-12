//
//  ProductionLine.swift
//  QuickShot
//
//  Created by Kieran Harper on 1/3/17.
//  Copyright © 2017 Amity Worldwide Pty Ltd. All rights reserved.
//

import UIKit
import Yakka

/* Object that can execute a number of tasks simultaneously and continue to accept and queue new tasks over its lifetime.
 This is a bit like a ParallelTask except that it lets you keep adding tasks while it runs, and there is no dependency between the tasks. A ProductionLine doesn't care whether tasks succeed or fail (you can attach handlers for that yourself), and never 'finishes' for itself - it will run as long as it lives.
 NOTE: While Task and its subclasses will retain itself while running, ProductionLine will not.
 */
public final class ProductionLine: NSObject {
    
    
    // MARK: - Properties
    
    public var maxConcurrentTasks: Int = 0
    public private(set) var isRunning = false
    
    
    
    // MARK: - Private variables
    
    private lazy var _pendingTasks = [Task]()
    private lazy var _runningTasks = [Task]()
    private let _internalQueue = DispatchQueue(label: "ProductionLinePipelineQueue")
    
    
    
    // MARK: - Public methods
    
    public func addTask(_ task: Task) {
        _internalQueue.async {
            self._pendingTasks.append(task)
            self.processSubtasks()
        }
    }
    
    public func addTasks(_ tasks: [Task]) {
        _internalQueue.async {
            self._pendingTasks.append(contentsOf: tasks)
            self.processSubtasks()
        }
    }
    
    public func start() {
        _internalQueue.async {
            if !self.isRunning {
                self.isRunning = true
                self.processSubtasks()
            }
        }
    }
    
    public func stop() {
        _internalQueue.async {
            self.isRunning = false
        }
    }
    
    public func cancelTasks() {
        _internalQueue.async {
            for task in self._runningTasks {
                task.cancel()
            }
            for task in self._pendingTasks {
                task.cancel()
            }
            self._pendingTasks.removeAll()
            self._runningTasks.removeAll()
        }
    }
    
    public func stopAndCancel() {
        stop()
        cancelTasks()
    }
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    /// Start tasks as needed, depending on max concurrency and number of pending tasks
    private func processSubtasks() {
        
        // Start any tasks we can and/or have remaining
        while (_runningTasks.count < maxConcurrentTasks || maxConcurrentTasks == 0), let next = _pendingTasks.first {
            startSubtask(next)
        }
    }
    
    /// Start a specific sub task
    private func startSubtask(_ task: Task) {
        
        // Move from pending into running
        move(subtask: task, fromCollection: &_pendingTasks, toCollection: &_runningTasks)
        
        // Schedule completion so we can consider starting new tasks
        task.onFinish(via: _internalQueue) { [weak self] (outcome) in
            guard let selfRef = self else { return }
            
            // Remove it from the running pile and consider starting any subsequent task/s
            remove(subtask: task, fromCollection: &selfRef._runningTasks)
            selfRef.processSubtasks()
        }
        
        // Kick it off
        task.start()
    }
}
