//
//  MultiTask.swift
//  Pods
//
//  Created by Kieran Harper on 27/12/16.
//
//

import Foundation

// Base class for tasks that manage the execution of a collection of tasks
public class MultiTask: Task {
    
    public var stopIfAnyFail = false
    
    private var _allTasks = Array<Task>()
    private var _pendingTasks = Array<Task>()
    private var _runningTasks = Array<Task>()
    private var _finishedTasks = Array<Task>()
    private let _internalQueue = DispatchQueue(label: "YakkaMultiTaskInternal")
    fileprivate var _maxParallelTasks = 0 // (0 == unlimited)
    private var _finishBlock: TaskFinishBlock?
    
    // TODO: overall progress tracking...
    
    
    // MARK: - Lifecycle
    
    public init(withTasks tasks: [Task]) {
        super.init()
        workToDo { (_, finish) in
            
            // Start executing tasks
            self._finishBlock = finish
            self._allTasks = tasks
            self._pendingTasks = tasks
            self.processSubtasks()
        }
    }
    
    public func useQueueForSubtaskWork(_ queue: DispatchQueue) {
        _internalQueue.sync {
            for task in _allTasks {
                task.queueForWork = queue
            }
        }
    }
    
    
    
    // MARK: - Private (ON ANY)
    
    private func processSubtasks() {
        _internalQueue.async {
            self.doProcessSubtasks()
        }
    }
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    private func doProcessSubtasks() {
        
        // Check for cancellation by passing it on to subtasks
        if currentState == .cancelling {
            for task in _allTasks {
                task.cancel()
            }
        }
        
        // Start any tasks we can and/or have remaining
        while (_runningTasks.count < _maxParallelTasks || _maxParallelTasks == 0), let next = _pendingTasks.first {
            self.startSubtask(next)
        }
        
        // Finish up if there's nothing left we're waiting on
        if _pendingTasks.count == 0, _runningTasks.count == 0 {
            
            // Consider whether or not we're here because all our tasks were actually cancelling
            if currentState == .cancelling {
                _finishBlock?(.cancelled)
            } else {
                _finishBlock?(.successful)
            }
            _finishBlock = nil
        }
    }
    
    private func startSubtask(_ task: Task) {
        
        // Move from pending into running
        move(subtask: task, fromCollection: &_pendingTasks, toCollection: &_runningTasks)
        
        // Schedule completion
        task.onFinish { (outcome) in
            self._internalQueue.async {
                self.subtaskFinished(task, withOutcome: outcome)
            }
        }
        
        // Kick it off
        task.start()
    }
    
    private func subtaskFinished(_ task: Task, withOutcome outcome: Result) {
        
        // Put it in the finished pile
        move(subtask: task, fromCollection: &_runningTasks, toCollection: &_finishedTasks)
        
        // If we're supposed to fail whenever an outcome isn't successful, then handle that now
        if stopIfAnyFail, outcome != .successful {
            for running in _runningTasks {
                running.cancel()
            }
            _finishBlock?(.failed)
            return
        }
        
        // Otherwise consider starting any subsequent task/s
        processSubtasks()
    }
    
    private func move(subtask: Task, fromCollection: inout Array<Task>, toCollection: inout Array<Task>) {
        if let index = indexOf(subtask: subtask, inCollection: fromCollection) {
            fromCollection.remove(at: index)
            toCollection.append(subtask)
        }
    }
    
    private func indexOf(subtask: Task, inCollection collection: Array<Task>) -> Int? {
        return collection.index { (t) -> Bool in
            return t == subtask
        }
    }
}



// Task that serializes subtask execution so that each one waits for completion of the one before it.
public class SerialTask: MultiTask {
    
    public override init(withTasks tasks: [Task]) {
        super.init(withTasks: tasks)
        _maxParallelTasks = 1
    }
}



// Task that allows multiple subtasks to run concurrently with one another.
public class ParallelTask: MultiTask {
    
    // Optional limit on the number of subtasks that can run concurrently. 0 == unlimited (the default)
    public var maxNumberOfTasks: Int {
        get {
            return _maxParallelTasks
        }
        set {
            _maxParallelTasks = newValue
        }
    }
}
