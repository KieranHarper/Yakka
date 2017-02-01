// https://github.com/Quick/Quick

import Quick
import Nimble
import Yakka

class YakkaSpec: QuickSpec {
    
    private func suceedingTask() -> Task {
        let task = Task { (process) in
            let delay: TimeInterval = 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                process.succeed()
            }
        }
        return task
    }
    
    private func failingTask() -> Task {
        let task = Task { (process) in
            let delay: TimeInterval = 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                process.fail()
            }
        }
        return task
    }
    
    private func processAwareSucceedingTask() -> Task {
        let task = Task { (process) in
            let step: TimeInterval = 0.5
            DelayableForLoop.loop(throughItems: [1, 2, 3, 4], delayBetweenLoops: step, itemHandler: { (item) in
                if process.shouldCancel { process.cancel(); return; }
                process.progress(Float(item) / 4.0)
            }, completionHandler: {
                process.succeed()
            })
        }
        return task
    }
    
    private func setOfSuccedingTasks() -> [Task] {
        var tasks = [Task]()
        for _ in 0...4 {
            let t = Task { (process) in
                let delay: TimeInterval = 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    process.succeed()
                }
            }
            tasks.append(t)
        }
        return tasks
    }
    
    override func spec() {
        
        describe("any task") {
            
            var task: Task!
            let waitTime: TimeInterval = 3.0
            
            beforeEach {
                task = self.suceedingTask()
            }
            
            it("should begin in 'not started' state") {
                expect(task.currentState).to(equal(Task.State.notStarted))
            }
            
            it("should transition to 'running' state only when it actually starts to run") {
                waitUntil(timeout: waitTime) { (done) in
                    task.onStart {
                        expect(task.currentState).to(equal(Task.State.running))
                        done()
                    }
                    task.start()
                    expect(task.currentState).to(equal(Task.State.notStarted))
                }
            }
            
            it("should not be able to run again if already been run") {
                waitUntil(timeout: waitTime) { (done) in
                    let toSucceed = self.suceedingTask()
                    toSucceed.start(onFinish: { (_) in
                        expect(toSucceed.currentState).to(equal(Task.State.successful))
                        toSucceed.start()
                        expect(toSucceed.currentState).to(equal(Task.State.successful))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            expect(toSucceed.currentState).to(equal(Task.State.successful))
                            done()
                        }
                    })
                }
                
                waitUntil(timeout: waitTime) { (done) in
                    let toFail = self.failingTask()
                    toFail.start(onFinish: { (_) in
                        expect(toFail.currentState).to(equal(Task.State.failed))
                        toFail.start()
                        expect(toFail.currentState).to(equal(Task.State.failed))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            expect(toFail.currentState).to(equal(Task.State.failed))
                            done()
                        }
                    })
                }
            }
            
            it("should never finish if the work doesn't") {
                var hit = false
                let hangingTask = Task { (process) in
                    // do nothing...
                }
                hangingTask.start(onFinish: { (outcome) in
                    hit = true // never gets here
                })
                expect(hit).toEventually(equal(false))
            }
            
            
            it("should fail if no work is provided") {
                waitUntil(timeout: waitTime) { (done) in
                    let toFail = Task()
                    toFail.start(onFinish: { (outcome) in
                        expect(toFail.currentState).to(equal(Task.State.failed))
                        done()
                    })
                }
            }
            
            it("should allow the work to be specified any time before being started") {
                let toConfigure = Task()
                var hit = false
                toConfigure.workToDo { (process) in
                    hit = true
                    process.succeed()
                }
                toConfigure.start()
                expect(hit).toEventually(equal(true))
            }
            
            it("should be retrievable by ID, but only while running") {
                
                waitUntil(timeout: waitTime) { (done) in
                    
                    // Before running
                    var possibleTask: Task? = nil
                    possibleTask = Task.with(ID: task.identifier)
                    expect(possibleTask).to(beNil())
                    
                    // While running
                    task.onStart {
                        possibleTask = Task.with(ID: task.identifier)
                        expect(possibleTask).notTo(beNil())
                    }
                    
                    // After running
                    task.onFinish { (outcome) in
                        possibleTask = Task.with(ID: task.identifier)
                        expect(possibleTask).to(beNil())
                        done()
                    }
                    
                    // Before it actually starts
                    task.start()
                    possibleTask = Task.with(ID: task.identifier)
                    expect(possibleTask).to(beNil())
                }
            }
            
            it("should transition to 'cancelling' even if it isn't cancel-aware") {
                waitUntil(timeout: waitTime) { (done) in
                    task.start()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        task.cancel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            expect(task.currentState).to(equal(Task.State.cancelling))
                            done()
                        }
                    }
                    
                }
            }
        }
        
        describe("a successful task") {
            
            var task: Task!
            let waitTime: TimeInterval = 3.0
            
            beforeEach {
                task = self.suceedingTask()
            }
            
            it("should run the finish handler with 'success'") {
                
                waitUntil(timeout: waitTime) { (done) in
                    task.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                }
            }
            
            it("should be able to succeed eventually after N retries") {
                waitUntil(timeout: 10.0) { (done) in
                    var count = 0
                    let eventuallySucceed = Task() { (process) in
                        count = count + 1
                        if count < 3 {
                            process.fail()
                        } else {
                            process.succeed()
                        }
                    }
                    eventuallySucceed.retryWaitTimeline = [0.5, 1.0, 1.5]
                    eventuallySucceed.start() { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                }
            }
        }
        
        describe("a failing task") {
            
            var task: Task!
            let waitTime: TimeInterval = 3.0
            
            beforeEach {
                task = self.failingTask()
            }
            
            it("should run the finish handler with 'failure'") {
                
                waitUntil(timeout: waitTime) { (done) in
                    task.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.failure))
                        done()
                    }
                }
            }
            
            it("should retry N times before giving up") {
                waitUntil(timeout: 10.0) { (done) in
                    var hit = false
                    task.retryWaitTimeline = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: 3, startingAt: 0)
                    task.onRetry {
                        hit = true
                    }
                    task.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.failure))
                        expect(hit).to(equal(true))
                        done()
                    }
                }
            }
        }
        
        describe("a process-aware task") {
            
            var task: Task!
            let waitTime: TimeInterval = 5.0
            
            beforeEach {
                task = self.processAwareSucceedingTask()
            }
            
            it("should finish with 'cancelled' if asked to cancel while running") {
                waitUntil(timeout: waitTime) { (done) in
                    task.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.cancelled))
                        done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        task.cancel()
                    }
                }
            }
            
            it("should generate notifications about progress") {
                waitUntil(timeout: waitTime) { (done) in
                    var hit = false
                    task.onProgress { (percent) in
                        print("task progress: \(percent)")
                        hit = true
                    }
                    task.start() { (outcome) in
                        expect(hit).to(equal(true))
                        done()
                    }
                }
            }
        }
        
        describe("a dependent task") {
            
            var toSucceed: Task!
            var toFail: Task!
            var toWait: Task!
            let waitTime: TimeInterval = 5.0
            
            beforeEach {
                toSucceed = self.suceedingTask()
                toFail = self.failingTask()
                toWait = self.suceedingTask()
            }
            
            it("should start only if another one finishes first") {
                waitUntil(timeout: waitTime) { (done) in
                    toWait.onStart {
                        expect(toSucceed.currentState).to(equal(Task.State.successful))
                        done()
                    }
                    toWait.start(after: toSucceed)
                    toSucceed.start()
                }
            }
            
            it("should start only if another one finishes with one or more specific outcomes") {
                waitUntil(timeout: waitTime) { (done) in
                    toWait.onStart {
                        expect(toFail.currentState).to(equal(Task.State.failed))
                        done()
                    }
                    toWait.start(after: toFail, finishesWith: [.failure, .cancelled])
                    toFail.start()
                }
            }
        }
        
        describe("a multi task") {
            
            it("should provide overall progress") {
                var tasks = [Task]()
                for _ in 0...10 {
                    let t = self.processAwareSucceedingTask()
                    tasks.append(t)
                }
                
                waitUntil(timeout: 5.0) { (done) in
                    let parallel = ParallelTask(involving: tasks)
                    parallel.onProgress { (percent) in
                        expect(percent).to(beGreaterThanOrEqualTo(0.0))
                        expect(percent).to(beLessThanOrEqualTo(1.0))
                    }
                    parallel.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                }
            }
            
            it("should allow subtasks to fail without overall failure (by default)") {
                var tasks = [Task]()
                for ii in 0...5 {
                    if ii == 3 {
                        tasks.append(self.failingTask())
                    } else {
                        tasks.append(self.suceedingTask())
                    }
                }
                
                waitUntil(timeout: 10.0) { (done) in
                    let serial = SerialTask(involving: tasks)
                    serial.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                }
            }
            
            it("should be configurable to fail overall if any subtask fails") {
                var tasks = [Task]()
                for ii in 0...5 {
                    if ii == 3 {
                        tasks.append(self.failingTask())
                    } else {
                        tasks.append(self.suceedingTask())
                    }
                }
                
                waitUntil(timeout: 10.0) { (done) in
                    let serial = SerialTask(involving: tasks)
                    serial.requireSuccessFromSubtasks = true
                    serial.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.failure))
                        done()
                    }
                }
            }
            
            it("should prevent pending subtasks from starting when canceling") {
                var startFlags = [Int]()
                let numTasks = 5
                var tasks = [Task]()
                for ii in 0..<numTasks {
                    let t = self.processAwareSucceedingTask()
                    t.onStart {
                        startFlags.append(ii)
                    }
                    tasks.append(t)
                }
                
                waitUntil(timeout: 10.0) { (done) in
                    let serial = SerialTask(involving: tasks)
                    serial.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.cancelled))
                        expect(startFlags.count).to(beLessThan(numTasks))
                        done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        serial.cancel()
                    }
                }
            }
        }
        
        describe("a serial task") {
            it("should run tasks to completion in the right order") {
                
                let expectedOrder: [Int] = [0, 1, 2, 3, 4]
                var flags = [Int]()
                var tasks = [Task]()
                for ii in expectedOrder {
                    let t = Task { (process) in
                        let delay: TimeInterval = 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            process.succeed()
                        }
                    }
                    t.onStart {
                        DispatchQueue.main.async {
                            flags.append(ii)
                        }
                    }
                    tasks.append(t)
                }
                
                waitUntil(timeout: 3.0) { (done) in
                    let serial = SerialTask(involving: tasks)
                    serial.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        expect(flags).to(equal(expectedOrder))
                        done()
                    }
                }
            }
        }
        
        describe("a parallel task") {
            it("should start no more than the specified max at a time") {
                let maxTasks = 4
                var startFlags = [Int]()
                var tasks = [Task]()
                for ii in 0...10 {
                    let t = Task { (process) in
                        let delay: TimeInterval = 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            process.succeed()
                        }
                    }
                    t.onStart {
                        DispatchQueue.main.async {
                            startFlags.append(ii)
                            expect(startFlags.count).to(beLessThanOrEqualTo(maxTasks))
                        }
                    }
                    t.onFinish(handler: { (_) in
                        DispatchQueue.main.async {
                            startFlags.removeLast()
                        }
                    })
                    tasks.append(t)
                }
                
                waitUntil(timeout: 5.0) { (done) in
                    let parallel = ParallelTask(involving: tasks)
                    parallel.maxConcurrentTasks = maxTasks
                    parallel.start { (outcome) in
                        expect(outcome).to(equal(Task.Outcome.success))
                        done()
                    }
                }
            }
        }
        
        describe("exponential backoff") {
            
            var a: [TimeInterval]!
            var b: [TimeInterval]!
            var c: [TimeInterval]!
            var d: [TimeInterval]!
            var e: [TimeInterval]!
            
            beforeEach {
                let numRetries = 5
                a = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: 0.0)
                b = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: -10.0)
                c = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: 0.5)
                d = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: 1.0)
                e = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: numRetries, startingAt: 3.0)
            }
            
            it("should start with initial value (when positive)") {
                expect(a[0]).to(equal(0.0))
                expect(b[0]).to(equal(0.0))
                expect(c[0]).to(equal(0.5))
                expect(d[0]).to(equal(1.0))
                expect(e[0]).to(equal(3.0))
            }
            
            it("should always increase exponentially from the initial value") {
                func checkTimeline(_ timeline: [TimeInterval]) {
                    for ii in 1..<timeline.count {
                        if ii == 1 {
                            expect(timeline[ii]).to(beGreaterThan(0.0))
                        } else {
                            expect(timeline[ii]).to(equal(2.0 * timeline[ii - 1]))
                        }
                    }
                }
                checkTimeline(a)
                checkTimeline(b)
                checkTimeline(c)
                checkTimeline(d)
                checkTimeline(e)
            }
        }
    }
}







private class DelayableForLoop: NSObject {
    
    override private init() { super.init() }
    
    public class func loop<T>(throughItems items: Array<T>, delayBetweenLoops: TimeInterval, initialDelay: TimeInterval = 0, itemHandler: @escaping (T)->(), completionHandler: @escaping ()->()) {
        
        // Create instance to do the work
        let worker = DelayableForLoop()
        
        // Begin the work after any provided start delay
        worker.processNext(inItems: items, afterDelay: initialDelay, delayToUseNext: delayBetweenLoops, itemHandler: itemHandler, completionHandler: completionHandler)
    }
    
    private func processNext<T>(inItems items: Array<T>, afterDelay delay: TimeInterval, delayToUseNext: TimeInterval, itemHandler: @escaping (T)->(), completionHandler: @escaping ()->()) {
        
        // Get the next item if there is one, otherwise finish immediately
        var workingItems = items
        guard let nextItem = workingItems.first else {
            completionHandler()
            return
        }
        
        // Wait the delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            
            // Do the work and proceed
            itemHandler(nextItem)
            workingItems.remove(at: 0)
            self.processNext(inItems: workingItems, afterDelay: delayToUseNext, delayToUseNext: delayToUseNext, itemHandler: itemHandler, completionHandler: completionHandler)
        }
    }
}

