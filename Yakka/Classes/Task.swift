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
    
    public enum Outcome {
        case success, cancelled, failure
    }
    
    
    // Helper object to give to work blocks so they can wrap things up and respond to cancellation
    public class Process {
        
        // NOTE: We're ok with strong references to these things as the rule is, Tasks are strongly retained while running, and these process objects only have a lifetime as long as the running part of the Task lifecycle.
        private let _task: Task
        public let workQueue: DispatchQueue
        
        public var shouldCancel: Bool {
            return _task.currentState == .cancelling
        }
        
        init(task: Task) {
            _task = task
            workQueue = task.queueForWork
        }
        
        public func progress(_ percent: Float) {
            _task.reportProgress(percent)
        }
        
        public func succeed() {
            _task.finish(withOutcome: .success)
        }
        
        public func cancel() {
            _task.finish(withOutcome: .cancelled)
        }
        
        public func fail() {
            _task.failOrRetry()
        }
    }
    
    public typealias TaskWorkClosure = (_ process: Process)->()
    
    // Handler types for reporting about the process
    public typealias StartHandler = ()->()
    public typealias FinishHandler = (_ outcome: Outcome)->()
    public typealias ProgressHandler = (_ percent: Float)->()
    public typealias RetryHandler = StartHandler
    
    
    
    // MARK: - Properties
    
    public final private(set) var identifier = UUID().uuidString
    public final private(set) var currentState = State.notStarted
    public final var queueForWork: DispatchQueue = DispatchQueue(label: "YakkaWorkQueue", attributes: .concurrent)
    public final var queueForStartFeedback = DispatchQueue.main
    public final var queueForProgressFeedback = DispatchQueue.main
    public final var queueForFinishFeedback = DispatchQueue.main
    public final var queueForRetryFeedback = DispatchQueue.main
    public final var retryWaitTimeline: [TimeInterval]? { // delays to use between retry attempts (if any)
        didSet {
            if let timeline = retryWaitTimeline {
                _retryConfig = TaskRetryHelper(waitTimeline: timeline)
            } else {
                _retryConfig = nil
            }
        }
    }
    
    
    // MARK: - Private variables
    
    private let _internalQueue = DispatchQueue(label: "YakkaTaskInternal")
    private var _workToDo: TaskWorkClosure?
    private var _startHandlers = Array<(StartHandler, DispatchQueue?)>()
    private var _progressHandlers = Array<(ProgressHandler, DispatchQueue?)>()
    private var _finishHandlers = Array<(FinishHandler, DispatchQueue?)>()
    private var _retryHandlers = Array<(RetryHandler, DispatchQueue?)>()
    private var _retryConfig: TaskRetryHelper?
    private var _strongSelfWhileWaitingForDependencyToFinish: Task? // only used in start() for dependent tasks
    
    static private var _cachedTasks = Dictionary<String, Task>()
    static private let _cachedTasksSafetyQueue = DispatchQueue(label: "YakkaTaskCacheSafety", attributes: .concurrent)
    
    
    
    // MARK: - Lifecycle
    
    public override init() {
        super.init()
        setupTask(workBlock: nil)
    }
    
    public final class func find(withID identifier: String) -> Task? {
        var toReturn: Task? = nil
        _cachedTasksSafetyQueue.sync {
            toReturn = _cachedTasks[identifier]
        }
        return toReturn
    }
    
    public init(withWork workBlock: @escaping TaskWorkClosure) {
        super.init()
        setupTask(workBlock: workBlock)
    }
    
    private func setupTask(workBlock: TaskWorkClosure?) {
        if let work = workBlock {
            workToDo(work)
        }
    }
    
    public final func workToDo(_ workBlock: @escaping TaskWorkClosure) {
        _internalQueue.async {
            self._workToDo = workBlock
        }
    }
    
    
    
    // MARK: - Control
    
    public final func start(onFinish finishHandler: FinishHandler? = nil) {
        
        // Pass on the finish handler
        if let handler = finishHandler {
            onFinish(via: nil, handler: handler)
        }
        
        // Get on the safe queue to change our state and get started via helper
        _internalQueue.async {
            self.internalStart()
            
            // Stop retaining ourself if we were (applies only to the dependent task not finishing yet case)
            self._strongSelfWhileWaitingForDependencyToFinish = nil
        }
    }
    
    public final func start(after task: Task, finishesWith allowedOutcomes: [Outcome] = [], onFinish finishHandler: FinishHandler? = nil) {
        
        // (where empty means any state)
        
        // Deliberately retain ourself so that we can go out of scope even though we're not running until the dependency finishes, without actually retaining ourself in the onFinish handler. This is done so that we can be cancelled and clean up when we haven't had a chance to run yet (special case for dependent tasks).
        _internalQueue.async {
            self._strongSelfWhileWaitingForDependencyToFinish = self
        }
        
        // Just attach to the dependent task's finish
        task.onFinish { [weak self] (outcome) in
            
            // Start us if the state falls within one of our options
            if allowedOutcomes.isEmpty || allowedOutcomes.contains(outcome) {
                self?.start(onFinish: finishHandler)
            }
                
                // Otherwise finish by passing on the dependent's outcome
            else {
                self?.finish(withOutcome: outcome)
            }
            
            self?._strongSelfWhileWaitingForDependencyToFinish = nil
        }
    }
    
    public final func cancel() {
        _internalQueue.async {
            
            // Change the state
            if self.currentState == .running {
                self.currentState = .cancelling
            }
            
            // Stop retaining ourself if we were (applies only to the dependent task not finishing yet case)
            self._strongSelfWhileWaitingForDependencyToFinish = nil
        }
    }
    
    
    
    // MARK: - Feedback
    
    public final func onStart(via queue: DispatchQueue? = nil, handler: @escaping ()->()) {
        _internalQueue.async {
            self._startHandlers.append((handler, queue))
        }
    }
    
    public final func onProgress(via queue: DispatchQueue? = nil, handler: @escaping ProgressHandler) {
        _internalQueue.async {
            self._progressHandlers.append((handler, queue))
        }
    }
    
    public final func onFinish(via queue: DispatchQueue? = nil, handler: @escaping FinishHandler) {
        _internalQueue.async {
            self._finishHandlers.append((handler, queue))
        }
    }
    
    public final func onRetry(via queue: DispatchQueue? = nil, handler: @escaping ()->()) {
        _internalQueue.async {
            self._retryHandlers.append((handler, queue))
        }
    }
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    private func internalStart() {
        
        // Only allowed to do this if we haven't been run yet
        guard currentState == .notStarted else { return }
        
        // Retain ourself and cache for retrieval later
        Task.cache(task: self, forID: identifier)
        
        // Ensure we actually have work to do, fail otherwise
        guard let work = _workToDo else {
            finish(withOutcome: .failure)
            return
        }
        
        // Change the state to running just before we do anything
        currentState = .running
        
        // If needed, start providing feedback about the fact we've started
        // NOTE: What's important is our currentState has changed, which can only happen on this internal queue and therefore just asking a task to start from any queue will not synchronously result in the state changing – we need this notification mechanism instead.
        let startHandlers = _startHandlers // copied for thread safety
        if startHandlers.count > 0 {
            queueForStartFeedback.async {
                for feedback in startHandlers {
                    
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
        
        // Actually start the work on the worker queue now
        queueForWork.async {
            work(Process(task: self))
        }
    }
    
    private func internalFinish(withOutcome outcome: Outcome) {
        
        // Don't do anything if we've already finished
        guard currentState != .successful, currentState != .failed, currentState != .cancelled else { return }
        
        // Change the state
        currentState = stateFromOutcome(outcome)
        
        // Remove ourself from the running cache / stop deliberately retaining self
        Task.cache(task: nil, forID: identifier)
        
        // Notify as needed
        let finishHandlers = _finishHandlers // copied for thread safety
        if finishHandlers.count > 0 {
            queueForFinishFeedback.async {
                for feedback in finishHandlers {
                    
                    // Use the custom queue override if applicable, otherwise run straight on the normal feedback queue
                    let handler = feedback.0
                    if let customQueue = feedback.1 {
                        customQueue.async {
                            handler(outcome)
                        }
                    } else {
                        handler(outcome)
                    }
                }
            }
        }
    }
    
    private func internalRetry() {
        
        // Only allowed to do this if we're currently running
        guard currentState == .running else { return }
        
        // Ensure we actually have work to do, fail otherwise
        guard let work = _workToDo else {
            finish(withOutcome: .failure)
            return
        }
        
        // If needed, provide feedback about the fact we've restarted
        let retryHandlers = _retryHandlers // copied for thread safety
        if retryHandlers.count > 0 {
            queueForRetryFeedback.async {
                for feedback in retryHandlers {
                    
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
        
        // Actually restart the work on the worker queue now
        queueForWork.async {
            work(Process(task: self))
        }        
    }
    
    
    
    // MARK: - Private (ON ANY)
    
    private func reportProgress(_ percent: Float) {
        if _progressHandlers.count > 0 {
            queueForProgressFeedback.async {
                for feedback in self._progressHandlers {
                    
                    // Use the custom queue override if applicable, otherwise run straight on the normal feedback queue
                    let handler = feedback.0
                    if let customQueue = feedback.1 {
                        customQueue.async {
                            handler(percent)
                        }
                    } else {
                        handler(percent)
                    }
                }
            }
        }
    }
    
    private func finish(withOutcome outcome: Outcome) {
        
        // Get on the safe queue and change the state
        _internalQueue.async {
            self.internalFinish(withOutcome: outcome)
        }
    }
    
    private func failOrRetry() {
        
        // Can only retry if we have a config, and it's up to that to decide if we've maxxed out the retries
        // NOTE: these handlers are gonna run straight on internal
        if let config = _retryConfig {
            config.retryOrNah(queue: _internalQueue, retry: {
                self.internalRetry()
            }, nah: {
                self.internalFinish(withOutcome: .failure)
            })
        } else {
            finish(withOutcome: .failure)
        }
    }
    
    private func stateFromOutcome(_ outcome: Outcome) -> State {
        switch outcome {
        case .success:
            return .successful
        case .cancelled:
            return .cancelled
        case .failure:
            return .failed
        }
    }
    
    private class func cache(task: Task?, forID identifier: String) {
        _cachedTasksSafetyQueue.async(flags: .barrier) {
            _cachedTasks[identifier] = task
        }
    }
}
