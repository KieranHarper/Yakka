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
    
    
    // MARK: - Types
    
    /// Handler that is used to notify that the line has become empty.
    public typealias BecameEmptyHandler = ()->()
    
    /// Handler that is used to notify that a task has been started.
    public typealias StartedTaskHandler = (Task)->()
    
    
    
    // MARK: - Properties
    
    /// Optional limit on the number of tasks that can run concurrently. Defaults to unlimited (0)
    public var maxConcurrentTasks: Int
    
    /// Whether or not the production line is running / will execute tasks upon adding (and when ready, depending on maxConcurrentTasks)
    public private(set) var isRunning = true
    
    /// The GCD queue on which tasks will perform their work
    public let workQueue: DispatchQueue
    
    /// The queue to deliver 'line is now empty' feedback on (default main)
    public final var queueForBecameEmptyFeedback = DispatchQueue.main
    
    /// The queue to deliver 'next task started' feedback on (default main)
    public final var queueForNextTaskStartedFeedback = DispatchQueue.main
    
    
    
    // MARK: - Private variables
    
    /// Set of tasks that have yet to be asked to run
    private lazy var _pendingTasks = [Task]()
    
    /// Set of tasks that have been asked to run
    private lazy var _runningTasks = [Task]()
    
    /// Queue providing serialization for state changing and other other thread sensitive things
    private let _internalQueue = DispatchQueue(label: "ProductionLineInternal", qos: .background)
    
    /// Set of handler + custom delivery queue pairings for those interested in 'line is now empty' feedback
    private var _becameEmptyHandlers = Array<(BecameEmptyHandler, DispatchQueue?)>()
    
    /// Set of handler + custom delivery queue pairings for those interested in 'next task started' feedback
    private var _taskStartedHandlers = Array<(StartedTaskHandler, DispatchQueue?)>()
    
    
    
    
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
    
    /// Register a closure to handle 'line is now empty' feedback, with an optional queue to use (overriding queueForBecameEmptyFeedback)
    public final func onBecameEmpty(via queue: DispatchQueue? = nil, handler: @escaping BecameEmptyHandler) {
        _internalQueue.async {
            self._becameEmptyHandlers.append((handler, queue))
        }
    }
    
    /// Register a closure to handle 'next task started' feedback, with an optional queue to use (overriding queueForNextTaskStartedFeedback)
    public final func onNextTaskStarted(via queue: DispatchQueue? = nil, handler: @escaping StartedTaskHandler) {
        _internalQueue.async {
            self._taskStartedHandlers.append((handler, queue))
        }
    }
    
    
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    /// Start tasks as needed, depending on max concurrency and number of pending tasks
    private func processSubtasks() {
        
        // Start any tasks we can and/or have remaining
        while isRunning, (_runningTasks.count < maxConcurrentTasks || maxConcurrentTasks == 0), let next = _pendingTasks.first {
            startSubtask(next)
        }
        
        // Notify when there aren't any more running tasks
        if _runningTasks.isEmpty {
            let emptiedHandlers = _becameEmptyHandlers // copied for thread safety
            if !emptiedHandlers.isEmpty {
                queueForBecameEmptyFeedback.async {
                    for feedback in emptiedHandlers {

                        // Use the custom queue override if applicable, otherwise run straight on the normal feedback queue
                        let handler = feedback.0
                        if let customQueue = feedback.1 {
                            customQueue.async {
                                handler()
                            }
                        } else {
                            handler()
                        }
                    }
                }
            }
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
        
        // Register for start feedback if we care about forwarding that information
        for handler in _taskStartedHandlers {
            task.onStart(via: handler.1) { [weak task] in
                if let strongTask = task { // (avoid capturing task in its own handler here...)
                    handler.0(strongTask)
                }
            }
        }
        
        // Kick it off
        task.start(using: workQueue)
    }
}
