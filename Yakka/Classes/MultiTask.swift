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
    private var _overallProcess: Process?
    private var _taskProgressions = Dictionary<String, Float>()
    
    
    // MARK: - Lifecycle
    
    public init(involving tasks: [Task]) {
        super.init()
        workToDo { (process) in
            
            // Start executing tasks
            self._overallProcess = process
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
                _overallProcess?.cancel()
            } else {
                _overallProcess?.succeed()
            }
            _overallProcess = nil
        }
    }
    
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
    
    private func subtaskFinished(_ task: Task, withOutcome outcome: Outcome) {
        
        // Put it in the finished pile
        move(subtask: task, fromCollection: &_runningTasks, toCollection: &_finishedTasks)
        
        // If we're supposed to fail whenever an outcome isn't successful, then handle that now
        if stopIfAnyFail, outcome != .success {
            for running in _runningTasks {
                running.cancel()
            }
            _overallProcess?.fail()
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
    
    public override init(involving tasks: [Task]) {
        super.init(involving: tasks)
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
