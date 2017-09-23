//
//  ProductionLine.swift
//  Yakka
//
//  Created by Kieran Harper on 1/3/17.
//
//

import Foundation
import Dispatch

/* Object that can execute a number of tasks simultaneously and continue to accept and queue new tasks over its lifetime.
 This is a bit like an OperationQueue in that you create one and add tasks to it as a way to coordinate execution.
 Tasks are started in the order they're added. You can control the maximum number that can be started before others finish, via the maxConcurrentTasks property.
 NOTE: While Task and its subclasses will retain itself while running, ProductionLine will not.
 */
public final class ProductionLine: NSObject {
    
    
    // MARK: - Properties
    
    /// Optional limit on the number of tasks that can run concurrently. Defaults to unlimited (0)
    public var maxConcurrentTasks: Int
    
    /// Whether or not the production line is running / will execute tasks upon adding (and when ready, depending on maxConcurrentTasks)
    public private(set) var isRunning = true
    
    /// The GCD queue on which tasks will perform their work
    public let workQueue: DispatchQueue
    
    
    
    // MARK: - Private variables
    
    /// Set of tasks that have yet to be asked to run
    private lazy var _pendingTasks = [Task]()
    
    /// Set of tasks that have been asked to run
    private lazy var _runningTasks = [Task]()
    
    /// Queue providing serialization for state changing and other other thread sensitive things
    private let _internalQueue = DispatchQueue(label: "ProductionLineInternal", qos: .background)
    
    
    
    
    // MARK: - Lifecycle
    
    public init(workQueue: DispatchQueue = DispatchQueue.global(qos: .background), maxConcurrentTasks: Int = 0) {
        self.workQueue = workQueue
        self.maxConcurrentTasks = maxConcurrentTasks
    }
    
    
    
    // MARK: - Public methods
    
    /// Add a task to the pipeline. If the pipeline is running then the task will be started asap, depending on maxConcurrentTasks
    public func addTask(_ task: Task) {
        _internalQueue.async {
            self._pendingTasks.append(task)
            self.processSubtasks()
        }
    }
    
    /// Add multiple tasks to the pipeline. If the pipeline is running then the task will be started asap, depending on maxConcurrentTasks
    public func addTasks(_ tasks: [Task]) {
        _internalQueue.async {
            self._pendingTasks.append(contentsOf: tasks)
            self.processSubtasks()
        }
    }
    
    /// Add a task to the pipeline using a closure. This approach can facilitate easier comprehension at the call site.
    public func add(using closure: ()->Task) {
        addTask(closure())
    }
    
    /// Start the pipeline. This will start any tasks that were already added (up to maxConcurrentTasks)
    public func start() {
        _internalQueue.async {
            if !self.isRunning {
                self.isRunning = true
                self.processSubtasks()
            }
        }
    }
    
    /// Stops the pipeline from starting any new tasks, until the next time you ask it to start. Tasks that were already running are unaffected by this.
    public func stop() {
        _internalQueue.async {
            self.isRunning = false
        }
    }
    
    /// Ask all the currently executing tasks to cancel themselves and remove everything from the pipeline. The pipeline will still be running after this, ready to accept and start new tasks.
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
    
    /// Stop the pipeline and also cancel/clear out all the running and pending tasks.
    public func stopAndCancel() {
        stop()
        cancelTasks()
    }
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    /// Start tasks as needed, depending on max concurrency and number of pending tasks
    private func processSubtasks() {
        
        // Start any tasks we can and/or have remaining
        while isRunning, (_runningTasks.count < maxConcurrentTasks || maxConcurrentTasks == 0), let next = _pendingTasks.first {
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
        task.start(using: workQueue)
    }
}
