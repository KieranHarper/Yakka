//
//  Task.swift
//  Yakka
//
//  Created by Kieran Harper on 27/12/16.
//
//

import Foundation

/// Building block for work that needs doing
open class Task: NSObject {
    
    
    
    // MARK: - Public types
    
    /// Task lifecycle state
    public enum State {
        
        // Running cases
        case notStarted, running, cancelling
        
        // Finished cases
        case successful, cancelled, failed
    }
    
    /// Possible outcomes when finished
    public enum Outcome {
        case success, cancelled, failure
    }
    
    /// Helper object to give to work closures so they can finish up or respond to cancellation
    public final class Process {
        
        /// The queue that the task is supposed to use for working (useful to access if your work closure needs to do nested async stuff and needs to provide a working queue)
        public final let workQueue: DispatchQueue
        
        /// Whether or not the work closure should bail early and call cancel()
        public final var shouldCancel: Bool {
            guard let t = _task else { return true }
            return t.currentState == .cancelling
        }
        
        /// Provide a closure to run (on the work queue) when shouldCancel changes to true. Useful if you want to support canceling your work but can't poll shouldCancel.
        public final func onShouldCancel(handler: @escaping ()->()) {
            _task?.storeOnCancelHandler(handler: handler)
        }
        
        /// Provide feedback about task progress
        public final func progress(_ percent: Float) {
            _task?.reportProgress(percent)
        }
        
        /* Provide feedback about task progress using polling.
         This differs from progress(percent) in that the process will periodically ask you for the progress, rather than you providing it when you want to. It's less efficient because the process doesn't know anything about your work and therefore will either ask more often than needed or not often enough (when the goal is to keep interested parties eg UI up to date). However, depending on the work you're doing, this may be the only approach you have (eg your underlying work uses something which only offers a progress property you have to poll).
         The default polling interval should be fine for most cases, but if your task is particuarly high res in it's measuring of progress then a faster interval might give nicer results.
         Calling this method subsequent times will stop and replace (passing a nil closure can stop it).
         */
        public final func progress(every interval: TimeInterval = 0.25, provider: (()->Float)?) {
            stopPolling()
            guard let provider = provider else { return }
            
            // Switch to main both for thread safety and also because we can't start a timer without a run loop
            DispatchQueue.main.async {
                self._pollMe = provider
                self._pollingTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(self.poll), userInfo: nil, repeats: true)
            }
        }
        
        /// Finish up with success
        public final func succeed() {
            stopPolling()
            _task?.finish(withOutcome: .success)
        }
        
        /// Finish up early due to cancellation
        public final func cancel() {
            stopPolling()
            _task?.finish(withOutcome: .cancelled)
        }
        
        /// Finish up with failure
        public final func fail() {
            stopPolling()
            _task?.failOrRetry()
        }
        
        
        /// Protected stuff:
        
        // NOTE: Task isn't retained because it's too easy to end up with a long winded retain cycle if the work closure of a task retains the process object (something they should be free to do without caring).
        private weak var _task: Task?
        private var _pollingTimer: Timer?
        private var _pollMe: (()->Float)?
        
        fileprivate init(task: Task) {
            _task = task
            workQueue = task.queueForWork
        }
        
        @objc private func poll() {
            
            // Get the value and pipe it through our other method
            guard let provider = _pollMe else {
                stopPolling()
                return
            }
            let percent = provider()
            progress(percent)
        }
        
        private func stopPolling() {
            DispatchQueue.main.async { // be thread safe
                self._pollingTimer?.invalidate()
                self._pollingTimer = nil
                self._pollMe = nil
            }
        }
    }
    
    /// Closure type used to provide the task's work and interact with the process
    public typealias TaskWorkClosure = (_ process: Process)->()
    
    /// Simple 'it started' feedback closure
    public typealias StartHandler = ()->()
    
    /// Finished feedback closure, providing the outcome
    public typealias FinishHandler = (_ outcome: Outcome)->()
    
    /// Closure that provides progress updates
    public typealias ProgressHandler = (_ percent: Float)->()
    
    /// Simple 'it started again' feedback closure
    public typealias RetryHandler = ()->()
    
    
    
    
    // MARK: - Properties
    
    /// Unique ID used to retieve task from the global cache later
    public final private(set) var identifier = UUID().uuidString
    
    /// State of the task's lifecycle
    public final private(set) var currentState = State.notStarted
    
    /// The queue to run the work closure on (default is a background queue)
    public final var queueForWork: DispatchQueue = DispatchQueue(label: "YakkaWorkQueue", attributes: .concurrent)
    
    /// The queue to deliver 'it started' feedback on (default main)
    public final var queueForStartFeedback = DispatchQueue.main
    
    /// The queue to deliver progress on (default main)
    public final var queueForProgressFeedback = DispatchQueue.main
    
    /// The queue to deliver 'it finished' feedback on (default main)
    public final var queueForFinishFeedback = DispatchQueue.main
    
    /// The queue to deliver 'it started again' feedback on (default main)
    public final var queueForRetryFeedback = DispatchQueue.main
    
    /* A set of wait times that characterise the behaviour of an autoretry system (used when the task says it failed).
     - Defaults to nil, meaning there's no autoretry behaviour at all.
     - The numbers represent the time delay between failure occurring and the task having another go.
     - There's one wait per retry, so the maximum number of retries is defined by the amount of waits.
     - This can be any combination of time intervals, including all zeros (for a no-wait retry schedule).
     - TaskRetryHelper provides a method to generate a sequence using exponential backoff.
     */
    public final var retryWaitTimeline: [TimeInterval]? {
        didSet {
            if let timeline = retryWaitTimeline {
                _retryHelper = TaskRetryHelper(waitTimeline: timeline)
            } else {
                _retryHelper = nil
            }
        }
    }
    
    
    
    
    // MARK: - Private variables
    
    /// Queue that isolates and coordinates operations such as state changing (otherwise thread-unsafe)
    private let _internalQueue = DispatchQueue(label: "YakkaTaskInternal")
    
    /// The closure containing the actual work
    private var _workToDo: TaskWorkClosure?
    
    /// Set of handler + custom delivery queue pairings for those interested in 'it started' feedback
    private var _startHandlers = Array<(StartHandler, DispatchQueue?)>()
    
    /// Set of handler + custom delivery queue pairings for those interested in progress feedback
    private var _progressHandlers = Array<(ProgressHandler, DispatchQueue?)>()
    
    /// Set of handler + custom delivery queue pairings for those interested in 'it finished' feedback
    private var _finishHandlers = Array<(FinishHandler, DispatchQueue?)>()
    
    /// Set of handler + custom delivery queue pairings for those interested in 'it started again' feedback
    private var _retryHandlers = Array<(RetryHandler, DispatchQueue?)>()
    
    /// Helper that assists in tracking the number of retry attempts and performing the delays (nil when no retry behaviour asked for)
    private var _retryHelper: TaskRetryHelper?
    
    /// Strong reference to ourself used only in start() when the task is dependent on another finishing. Tasks retaining themselves while running is actually due to _cachedTasks, not this.
    private var _strongSelfWhileWaitingForDependencyToFinish: Task?
    
    /// Handler that will be run when the state transitions to cancelling
    private var _onCancellingHandler: (()->())?
    
    
    
    
    // MARK: - Statics
    
    /// Global cache of all currently running tasks. This is used to ensure they're retained so the user doesn't have to, and also allows tasks to be retrieved by ID (only if they're running).
    static private var _cachedTasks = Dictionary<String, Task>()
    
    /// Queue that serializes access to _cachedTasks for thread safety
    static private let _cachedTasksSafetyQueue = DispatchQueue(label: "YakkaTaskCacheSafety", attributes: .concurrent)
    
    
    
    
    // MARK: - Lifecycle
    
    /// Constructor for when you want to provide the work closure at a later stage
    public override init() {
        super.init()
        setupTask(workBlock: nil)
    }
    
    /// Construct with work to do
    public init(withWork workBlock: @escaping TaskWorkClosure) {
        super.init()
        setupTask(workBlock: workBlock)
    }
    
    private func setupTask(workBlock: TaskWorkClosure?) {
        if let work = workBlock {
            workToDo(work)
        }
    }
    
    /// Retrieve a currently running task by ID
    public final class func find(withID identifier: String) -> Task? {
        var toReturn: Task? = nil
        _cachedTasksSafetyQueue.sync {
            toReturn = _cachedTasks[identifier]
        }
        return toReturn
    }
    
    /// Provide or change the work that the task actually does
    public final func workToDo(_ workBlock: @escaping TaskWorkClosure) {
        _internalQueue.async {
            self._workToDo = workBlock
        }
    }
    
    
    
    
    // MARK: - Control
    
    /// Ask the task to start, with the option to attach a handler to run when it finishes
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
    
    /// Ask the task to start as soon as another dependent task finishes, with options on which outcomes are allowed, and optional handler to run when this task eventually finishes
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
    
    /// Ask the task to cancel. Only tasks whose work is 'cancel-aware' will actually finish early with a cancelled outcome.
    public final func cancel() {
        _internalQueue.async {
            
            // Change the state
            if self.currentState == .running {
                self.currentState = .cancelling
            }
            
            // Notify the work of the task itself that the state changed to cancelling (in case it wants to support cancelling but can't poll for the state)
            if let handler = self._onCancellingHandler {
                self.queueForWork.async {
                    handler()
                }
            }
            
            // Stop retaining ourself if we were (applies only to the dependent task not finishing yet case)
            self._strongSelfWhileWaitingForDependencyToFinish = nil
        }
    }
    
    
    
    
    // MARK: - Feedback
    
    /// Register a closure to handle 'it started' feedback, with an optional queue to use (overriding queueForStartFeedback)
    public final func onStart(via queue: DispatchQueue? = nil, handler: @escaping ()->()) {
        _internalQueue.async {
            self._startHandlers.append((handler, queue))
        }
    }
    
    /// Register a closure to handle progress feedback, with an optional queue to use (overriding queueForProgressFeedback)
    public final func onProgress(via queue: DispatchQueue? = nil, handler: @escaping ProgressHandler) {
        _internalQueue.async {
            self._progressHandlers.append((handler, queue))
        }
    }
    
    /// Register a closure to handle 'it finished' feedback, with an optional queue to use (overriding queueForFinishFeedback)
    public final func onFinish(via queue: DispatchQueue? = nil, handler: @escaping FinishHandler) {
        _internalQueue.async {
            self._finishHandlers.append((handler, queue))
        }
    }
    
    /// Register a closure to handle 'it started again' feedback, with an optional queue to use (overriding queueForRetryFeedback)
    public final func onRetry(via queue: DispatchQueue? = nil, handler: @escaping ()->()) {
        _internalQueue.async {
            self._retryHandlers.append((handler, queue))
        }
    }
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    /// Run the task's work and handle all the state tracking and notifications
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
    
    /// Wrap up the task by dealing with state changes and notifying
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
    
    /// Handle state stuff and make the task's work run again
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
    
    /// Helper to fire off progress feedback to waiting handlers
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
    
    /// Simple helper for finishing that makes queue management slightly clearer
    private func finish(withOutcome outcome: Outcome) {
        
        // Get on the safe queue and change the state
        _internalQueue.async {
            self.internalFinish(withOutcome: outcome)
        }
    }
    
    /// Encapsulates the interactions with the retry helper to either retry or wrap it up
    private func failOrRetry() {
        
        // Can only retry if we have a config, and it's up to that to decide if we've maxxed out the retries
        // NOTE: these handlers are gonna run straight on internal
        if let config = _retryHelper {
            config.retryOrNah(onQueue: _internalQueue, retry: {
                self.internalRetry()
            }, nah: {
                self.internalFinish(withOutcome: .failure)
            })
        } else {
            finish(withOutcome: .failure)
        }
    }
    
    /// Safely stores a handler that will notify task's work that it should be cancelling
    private func storeOnCancelHandler(handler: @escaping ()->()) {
        _internalQueue.async {
            self._onCancellingHandler = handler
            
            // Notify straight away if we're already in the cancelling state
            if self.currentState == .cancelling {
                self.queueForWork.async {
                    handler()
                }
            }
        }
    }
    
    /// Convert from an Outcome to the resulting lifecycle State
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
    
    /// Thread-safe write access to the tasks cache
    private class func cache(task: Task?, forID identifier: String) {
        _cachedTasksSafetyQueue.async(flags: .barrier) {
            _cachedTasks[identifier] = task
        }
    }
}
