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
        
        private weak var _task: Task?
        public let workQueue: DispatchQueue
        
        public var shouldCancel: Bool {
            return _task?.currentState == .cancelling
        }
        
        init(task: Task) {
            _task = task
            workQueue = task.queueForWork
        }
        
        public func progress(_ percent: Float) {
            _task?.reportProgress(percent)
        }
        
        public func succeed() {
            _task?.finish(withOutcome: .success)
        }
        
        public func cancel() {
            _task?.finish(withOutcome: .cancelled)
        }
        
        public func fail() {
            _task?.failOrRetry()
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
    public final private(set) var currentState = State.notStarted
    
    private let _internalQueue = DispatchQueue(label: "YakkaTaskInternal")
    private var _workToDo: TaskWorkClosure?
    private var _startHandlers = Array<(StartHandler, DispatchQueue?)>()
    private var _progressHandlers = Array<(ProgressHandler, DispatchQueue?)>()
    private var _finishHandlers = Array<(FinishHandler, DispatchQueue?)>()
    private var _retryHandlers = Array<(RetryHandler, DispatchQueue?)>()
    private var _retryConfig: TaskRetryHelper?
    
    static private var _cachedTasks = Dictionary<String, Task>()
    static private let _cachedTasksSafetyQueue = DispatchQueue(label: "YakkaTaskCacheSafety", attributes: .concurrent)
    
    
    
    // MARK: - Lifecycle
    
    public override init() {
        super.init()
        setupTask(workBlock: nil)
    }
    
    public final class func with(ID identifier: String) -> Task? {
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
            self.doStart()
        }
    }
    
    public final func start(after task: Task, finishesWith allowedOutcomes: [Outcome] = [], onFinish finishHandler: FinishHandler? = nil) {
        
        // (where empty means any state)
        
        // Just attach to the dependent task's finish
        task.onFinish { (outcome) in
            
            // Start us if the state falls within one of our options
            if allowedOutcomes.isEmpty || allowedOutcomes.contains(outcome) {
                self.start(onFinish: finishHandler)
            }
                
                // Otherwise finish by passing on the dependent's outcome
            else {
                self.finish(withOutcome: outcome)
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
    
    public final func onStart(via queue: DispatchQueue? = nil, handler: @escaping ()->()) {
        _internalQueue.async { [weak self] in
            self?._startHandlers.append((handler, queue))
        }
    }
    
    public final func onProgress(via queue: DispatchQueue? = nil, handler: @escaping ProgressHandler) {
        _internalQueue.async { [weak self] in
            self?._progressHandlers.append((handler, queue))
        }
    }
    
    public final func onFinish(via queue: DispatchQueue? = nil, handler: @escaping FinishHandler) {
        _internalQueue.async { [weak self] in
            self?._finishHandlers.append((handler, queue))
        }
    }
    
    public final func onRetry(via queue: DispatchQueue? = nil, handler: @escaping ()->()) {
        _internalQueue.async { [weak self] in
            self?._retryHandlers.append((handler, queue))
        }
    }
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    private func doStart() {
        
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
        self.currentState = .running
        
        // Actually start the work on the worker queue
        let startHandlers = self._startHandlers
        self.queueForWork.sync {
            
            // If needed, provide feedback about the fact we've started
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
            
            // OK GO
            work(Process(task: self))
        }
    }
    
    private func doFinish(withOutcome outcome: Outcome) {
        
        // Don't do anything if we've already finished
        guard currentState != .successful, currentState != .failed, currentState != .cancelled else { return }
        
        // Change the state
        self.currentState = stateFromOutcome(outcome)
        
        // Remove ourself from the running cache / stop deliberately retaining self
        Task.cache(task: nil, forID: identifier)
        
        // Now get on the feedback queue to finish up
        if self._finishHandlers.count > 0 {
            self.queueForFinishFeedback.sync {
                for feedback in self._finishHandlers {
                    
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
    
    private func doRetry() {
        
        // Only allowed to do this if we're currently running
        guard currentState == .running else { return }
        
        // Ensure we actually have work to do, fail otherwise
        guard let work = _workToDo else {
            finish(withOutcome: .failure)
            return
        }
        
        // Actually restart the work on the worker queue
        let retryHandlers = self._retryHandlers
        self.queueForWork.sync {
            
            // If needed, provide feedback about the fact we've restarted
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
            
            // OK GO
            work(Process(task: self))
        }
    }
    
    
    
    // MARK: - Private (ON ANY)
    
    private func reportProgress(_ percent: Float) {
        if self._progressHandlers.count > 0 {
            self.queueForProgressFeedback.async {
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
            self.doFinish(withOutcome: outcome)
        }
    }
    
    private func failOrRetry() {
        
        // Can only retry if we have a config, and it's up to that to decide if we've maxxed out the retries
        // NOTE: these handlers are gonna run straight on internal
        if let config = _retryConfig {
            config.retryOrNah(queue: _internalQueue, retry: {
                self.doRetry()
            }, nah: {
                self.doFinish(withOutcome: .failure)
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
