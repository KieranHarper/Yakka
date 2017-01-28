//
//  Task.swift
//  Pods
//
//  Created by Kieran Harper on 27/12/16.
//
//

import Foundation

public class Task: NSObject {
    
    
    // MARK: - Types
    
    public enum State {
        
        // Running cases
        case notStarted, running, cancelling
        
        // Finished cases
        case successful, cancelled, failed
    }
    
    public enum Result {
        case successful, cancelled, failed
    }
    
    public typealias ResultPasser = (_ result: Result)->()
    
    // Helper object to give to work blocks so they can wrap things up and respond to cancellation
    public class Process {
        
        private let task: Task
        
        public var shouldCancel: Bool {
            return task.currentState == .cancelling
        }
        
        init(task: Task) {
            self.task = task
        }
        
        public func progress(_ percent: Float) {
            task.reportProgress(percent)
        }
        
        public func succeed() {
            task.finish(withResult: .successful)
        }
        
        public func cancel() {
            task.finish(withResult: .cancelled)
        }
        
        public func fail() {
            task.finish(withResult: .failed)
        }
    }
    
    public typealias TaskWorkBlock = (_ process: Process)->()
    
    // Handler types for reporting about the process
    public typealias FinishHandler = ResultPasser
    public typealias ProgressHandler = (_ percent: Float)->()
    
    
    
    // MARK: - Properties
    
    public final private(set) var identifier = UUID().uuidString
    public final var queueForWork: DispatchQueue = DispatchQueue(label: "YakkaWorkQueue", attributes: .concurrent)
    public final var queueForFeedback = DispatchQueue.main
    public final private(set) var currentState = State.notStarted
    
    private let _internalQueue = DispatchQueue(label: "YakkaTaskInternal")
    private var _workToDo: TaskWorkBlock?
    private var _startHandlers = Array<(()->())>()
    private var _progressHandlers = Array<ProgressHandler>()
    private var _finishHandlers = Array<FinishHandler>()
    
    static private var _cachedTasks = Dictionary<String, Task>()
    
    
    
    // MARK: - Lifecycle
    
    public override init() {
        super.init()
        setupTask(workBlock: nil)
    }
    
    public final class func with(ID identifier: String) -> Task? {
        return _cachedTasks[identifier]
    }
    
    public init(withWork workBlock: @escaping TaskWorkBlock) {
        super.init()
        setupTask(workBlock: workBlock)
    }
    
    private func setupTask(workBlock: TaskWorkBlock?) {
        if let work = workBlock {
            workToDo(workBlock: work)
        }
    }
    
    public final func workToDo(workBlock: @escaping TaskWorkBlock) {
        _internalQueue.async {
            self._workToDo = workBlock
        }
    }
    
    
    
    // MARK: - Control
    
    public final func start(finishHandler: FinishHandler? = nil) {
        
        // Pass on the finish handler
        if let handler = finishHandler {
            onFinish(handler)
        }
        
        // Get on the safe queue to change our state and get started via helper
        _internalQueue.async {
            self.doStart()
        }
    }
    
    public final func start(afterTask task: Task, finishesWith allowedOutcomes: [Result] = [], finishHandler: FinishHandler? = nil) {
        
        // (where empty means any state)
        
        // Just attach to the dependent task's finish
        task.onFinish { (outcome) in
            
            // Start us if the state falls within one of our options
            if allowedOutcomes.isEmpty || allowedOutcomes.contains(outcome) {
                self.start(finishHandler: finishHandler)
            }
                
                // Otherwise finish by passing on the dependent's outcome
            else {
                self.finish(withResult: outcome)
            }
        }
    }
    
    public final func cancel() {
        _internalQueue.async { [weak self] in
            guard let selfRef = self else { return }
            if selfRef.currentState == .running {
                selfRef.currentState = .cancelling
            }
        }
    }
    
    
    
    // MARK: - Feedback
    
    public final func onStart(_ handler: @escaping ()->()) {
        _internalQueue.async { [weak self] in
            self?._startHandlers.append(handler)
        }
    }
    
    public final func onProgress(_ handler: @escaping ProgressHandler) {
        _internalQueue.async { [weak self] in
            self?._progressHandlers.append(handler)
        }
    }
    
    public final func onFinish(_ handler: @escaping FinishHandler) {
        _internalQueue.async { [weak self] in
            self?._finishHandlers.append(handler)
        }
    }
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    private func doStart() {
        
        // Only allowed to do this if we haven't been run yet
        guard currentState == .notStarted else { return }
        
        // Retain ourself and cache for retrieval later
        Task._cachedTasks[identifier] = self
        
        // Ensure we actually have work to do, fail otherwise
        guard let work = _workToDo else {
            finish(withResult: .failed)
            return
        }
        
        // Change the state to running just before we do anything
        self.currentState = .running
        
        // Actually start the work on the worker queue
        self.queueForWork.sync {
            work(Process(task: self))
        }
        
        // If needed, provide feedback about the fact we've started
        if self._startHandlers.count > 0 {
            queueForFeedback.async {
                for feedback in self._startHandlers {
                    feedback()
                }
            }
        }
    }
    
    private func doFinish(withResult result: Result) {
        
        // Don't do anything if we've already finished
        guard currentState != .successful, currentState != .failed, currentState != .cancelled else { return }
        
        // Change the state
        self.currentState = stateFromResult(result)
        
        // Now get on the feedback queue to finish up
        if self._finishHandlers.count > 0 {
            self.queueForFeedback.sync {
                for feedback in self._finishHandlers {
                    feedback(result)
                }
            }
        }
        
        // Remove ourself from the cache / stop retaining self
        Task._cachedTasks[identifier] = nil
    }
    
    
    
    // MARK: - Private (ON ANY)
    
    private func reportProgress(_ percent: Float) {
        if self._progressHandlers.count > 0 {
            self.queueForFeedback.async {
                for feedback in self._progressHandlers {
                    feedback(percent)
                }
            }
        }
    }
    
    private func finish(withResult result: Result) {
        
        // Get on the safe queue and change the state
        _internalQueue.async {
            self.doFinish(withResult: result)
        }
    }
    
    private func stateFromResult(_ result: Result) -> State {
        switch result {
        case .successful:
            return .successful
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        }
    }
    
    // TODO: Add autoretry capabilities
}
