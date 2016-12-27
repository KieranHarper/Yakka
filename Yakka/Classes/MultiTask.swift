//
//  MultiTask.swift
//  Pods
//
//  Created by Kieran Harper on 27/12/16.
//
//

import Foundation

public class MultiTask: Task {
    
    fileprivate var _maxParallelTasks = 0 // (0 == unlimited)
    
    public var stopIfAnyFail = false
    
    public init(withTasks tasks: [Task]) {
        super.init { (finish) in
            // (figure out how to run tasks together)
        }
    }
}

public class SerialTask: MultiTask {
    
    public override init(withTasks tasks: [Task]) {
        super.init(withTasks: tasks)
        _maxParallelTasks = 1
    }
}

public class ParallelTask: MultiTask {
    
    public var maxNumberOfTasks: Int {
        get {
            return _maxParallelTasks
        }
        set {
            _maxParallelTasks = newValue
        }
    }
}
