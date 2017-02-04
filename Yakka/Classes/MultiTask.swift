//
//  MultiTask.swift
//  Pods
//
//  Created by Kieran Harper on 27/12/16.
//
//

import Foundation

/// Base class for tasks that manage the execution of a collection of tasks. Recommend using ParallelTask or SerialTask, which subclass this.
open class MultiTask: Task {
    
    
    // MARK: - Properties
    
    /// Whether or not all the subtasks need to finish successfully in order to continue and finish with success overall.
    public var requireSuccessFromSubtasks = false
    
    
    
    
    // MARK: - Private variables
    
    /// Set of tasks we've been given
    private var _allTasks = Array<Task>()
    
    /// Set of tasks that have yet to be asked to run
    private var _pendingTasks = Array<Task>()
    
    /// Set of tasks that have been asked to run
    private var _runningTasks = Array<Task>()
    
    /// Set of tasks that have finished running
    private var _finishedTasks = Array<Task>()
    
    /// Queue providing serialization for state changing and other other thread sensitive things
    private let _internalQueue = DispatchQueue(label: "YakkaMultiTaskInternal")
    
    /// The maximum number of tasks we're going to ask to start before waiting for some to finish. Defaults to unlimited (0)
    fileprivate var _maxParallelTasks = 0
    
    /// The Process object for the overall task (this one)
    private var _overallProcess: Process?
    
    /// Tracking of the percent completion of each of the subtasks, in order to provide overall progress feedback
    private var _taskProgressions = Dictionary<String, Float>()
    
    
    
    
    // MARK: - Lifecycle
    
    /// Construct with the set of tasks to run together
    public init(involving tasks: [Task]) {
        super.init()
        workToDo { (process) in
            
            // Start executing tasks
            self._overallProcess = process
            self._allTasks = tasks
            self._pendingTasks = tasks
            self._internalQueue.async {
                self.processSubtasks()
            }
        }
    }
    
    /// Specify a working queue to apply to each of the subtasks. By default N different queues are used, since it's up to the Task instances.
    public final func useQueueForSubtaskWork(_ queue: DispatchQueue) {
        _internalQueue.async {
            for task in self._allTasks {
                task.queueForWork = queue
            }
        }
    }
    
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    /// Start tasks as needed, consider cancellation etc
    private func processSubtasks() {
        
        // Check for cancellation by passing it on to subtasks and prevent pending ones from starting
        if currentState == .cancelling {
            for task in _allTasks {
                task.cancel()
            }
            _pendingTasks.removeAll()
        }
        
        // Start any tasks we can and/or have remaining
        while (_runningTasks.count < _maxParallelTasks || _maxParallelTasks == 0), let next = _pendingTasks.first {
            startSubtask(next)
        }
        
        // Finish up if there's nothing left we're waiting on
        if _pendingTasks.count == 0, _runningTasks.count == 0 {
            
            // Consider whether or not we're here because all our tasks were actually cancelling
            if currentState == .cancelling {
                _overallProcess?.cancel()
            } else {
                _overallProcess?.succeed()
            }
            _overallProcess = nil
        }
    }
    
    /// Start a specific sub task, setting up progress reporting and completion etc
    private func startSubtask(_ task: Task) {
        
        // Move from pending into running
        move(subtask: task, fromCollection: &_pendingTasks, toCollection: &_runningTasks)
        
        // Handle progress, by accumulating the percentages of all tasks (they're equally weighted)
        task.onProgress(via: _internalQueue) { (percent) in
            self._taskProgressions[task.identifier] = percent
            let overallPercent = self._taskProgressions.reduce(0.0, { $0 + $1.value }) / Float(self._allTasks.count)
            self._overallProcess?.progress(overallPercent)
        }
        
        // Schedule completion
        task.onFinish { (outcome) in
            self._internalQueue.async {
                self.subtaskFinished(task, withOutcome: outcome)
            }
        }
        
        // Kick it off
        task.start()
    }
    
    /// Handle a subtask finishing, consider what to do next
    private func subtaskFinished(_ task: Task, withOutcome outcome: Outcome) {
        
        // Put it in the finished pile
        move(subtask: task, fromCollection: &_runningTasks, toCollection: &_finishedTasks)
        
        // If we're supposed to fail whenever an outcome isn't successful, then handle that now
        if requireSuccessFromSubtasks, outcome != .success {
            for running in _runningTasks {
                running.cancel()
            }
            _overallProcess?.fail()
            return
        }
        
        // Otherwise consider starting any subsequent task/s
        processSubtasks()
    }
    
    /// Helper to shift subtasks between sets for tracking
    private func move(subtask: Task, fromCollection: inout Array<Task>, toCollection: inout Array<Task>) {
        if let index = indexOf(subtask: subtask, inCollection: fromCollection) {
            fromCollection.remove(at: index)
            toCollection.append(subtask)
        }
    }
    
    /// Helper to find a task in a collection
    private func indexOf(subtask: Task, inCollection collection: Array<Task>) -> Int? {
        return collection.index { (t) -> Bool in
            return t == subtask
        }
    }
}




/// Task that serializes subtask execution so that each task waits for completion of the one before it
open class SerialTask: MultiTask {
    
    /// Construct with the set of tasks to run in order
    public override init(involving tasks: [Task]) {
        super.init(involving: tasks)
        _maxParallelTasks = 1
    }
}




/// Task that allows multiple subtasks to run concurrently with one another
open class ParallelTask: MultiTask {
    
    /// Optional limit on the number of subtasks that can run concurrently. Defaults to unlimited (0)
    public final var maxConcurrentTasks: Int {
        get {
            return _maxParallelTasks
        }
        set {
            _maxParallelTasks = newValue
        }
    }
}
