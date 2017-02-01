# Yakka

[![Version](https://img.shields.io/cocoapods/v/Yakka.svg?style=flat)](http://cocoapods.org/pods/Yakka)
[![License](https://img.shields.io/cocoapods/l/Yakka.svg?style=flat)](http://cocoapods.org/pods/Yakka)
[![Platform](https://img.shields.io/cocoapods/p/Yakka.svg?style=flat)](http://cocoapods.org/pods/Yakka)

## Features

Yakka is a toolkit for coordinating the doing of stuff. Here's what it does:
- Makes it trivial to do arbitrary work in the background and know when it finishes.
- Lets you easily group and/or chain independent chunks of background work to form trackable processes.
- Allows any number of interested parties to listen/track the progress and outcome of background work.
- Gives fine control over the GCD queues involved if required.

Yakka is designed for throwaway code you just need run asynchronously in the background, as well as for creating reusable task classes that encapsulate less trivial processes. There are many different ways of tackling this kind of thing – hopefully this one works for you!

#### Some details:
- Task class is a building block.
- Has sensible defaults tuned for casual use.
- Provide the work to do via a closure.
- Add progress handler/s if needed.
- Add finish handler/s in advance if it suits (as opposed to providing one via the start call).
- Provide a specific queue to work on if needed (new concurrent background used by default).
- Provide a specific queue for feedback to come through on if needed (main used by default).
- Start it when ready, with optional finish closure.
- Can also tell it to start after some other task has finished (with optional conditions on the outcome).
- Tasks retain themselves after starting, until finish closure is called.
- Tasks which are asked to start when another completes will also retain themselves even though they haven't started running yet (unless cancelled).
- The work closure is given an object which it uses to communicate progress and finishing etc, and can do so at any stage from any queue.
- Use ParallelTask to group independent Task objects and have them execute alongside each other with a final overall finish handler.
- Use SerialTask for a similar objective except the order matters and they execute one after another.
- Task instances are single shot – they can't be run again after they finish.

#### Lifecycle of a Yakka Task:
1. Not Started
1. Running
1. Cancelling
1. Successful | Cancelled | Failed

Some points about that:
- Flows downward and never back up.
- Cancelling only leads to Cancelled if task is cancel-aware and bails out.
- If a task never moves into Running, no handlers will ever be called.
- Tasks retain themselves only while Running and Cancelling, except for dependent tasks which will also do so when Not Started if you've asked them to start after the dependency.
- Because it never flows backwards, tasks cannot be restarted, even if cancelled.
- The exception to the above is dependent tasks that are cancelled while still in Not Started while they waited. In that case it behaves as if it was never asked to start yet.

#### A note on memory management:
Tasks retain themselves while running, which is done deliberately to make it easier to work with. The working queue used by the task is also retained while running. All you gotta do is make sure your work eventually finishes by calling one of the methods on the process object, and that the process object isn't retained beyond that point. If for example your task involves multiple async closures that need the process object but only one will run and clean up, ensure you only weakly capture the process object.

## Examples

### Trivial one-off work
```swift
Task(withWork: { (process) in
    // some call you wanted backgrounded here
    process.succeed()
}).start { (_) in
    // keep moving
}
```

### Less trivial one-off example
```swift
let someWork = Task { (process) in

    // do something here...

    // if you can, report progress periodically like this:
    process.progress(0.5) // percent 0..1

    // where it makes sense, check for cancellation and bail
    if process.shouldCancel {
        process.cancel()
        return
    }

    // (the above makes this a "process-aware task" - progress and cancellation)

    // finish up at some point using one of the following:
    process.fail()
    process.succeed()
}
someWork.onProgress { (percent) in
    // update your UI etc
}
someWork.onStart {
    // update your UI etc
}
someWork.onFinish { (outcome) in
    // outcome is one of .successful, .failed, .cancelled)
}
someWork.start()
```

### Trivial parallel grouping
```swift
var tasks = [Task]()
for ii in 0...4 {
    let t = Task { (process) in
        print(ii)
        process.succeed()
    }
    tasks.append(t)
}
ParallelTask(involving: tasks).start { (outcome) in
    print("parallel execution is all done")
}
```

### Trivial serial grouping
```swift
var tasks = [Task]()
for ii in 0...4 {
    let t = Task { (process) in
        print(ii)
        process.succeed()
    }
    tasks.append(t)
}
SerialTask(involving: tasks).start { (outcome) in
    print("serial execution is all done")
}
```

### Conditional chain example
```swift
let first = Task { (process) in
    print("first work")
    process.fail()
}
let second = Task { (process) in
    print("second work")
    process.succeed()
}
second.start(after: first, finishesWith: [.success]) { (outcome) in
    // (this won't happen because first task fails, therefore second never starts)
}
first.retryWaitTimeline = TaskRetryHelper.exponentialBackoffTimeline(forMaxRetries: 3, startingAt: 0.5)
first.onRetry {
    print("retrying...")
}
first.start()
```

### Reusable process approach
```swift
class DigMassiveHole: Task {

    let diameter: Float
    let depth: Float
    var numEmployees = 1

    init(diameter: Float, depth: Float) {

        // Some config
        self.diameter = diameter
        self.depth = depth
        super.init()

        // Define what this task does
        workToDo { (process) in

            // do some digging...

            process.succeed()
        }
    }
}

let dig = DigMassiveHole(diameter: 30, depth: 100)
dig.numEmployees = 5
dig.start { (outcome) in
    print("did the thing!")
}
```

These examples all complete their work by the end of the work closure (they're synchronous), but you can check out the tests file for a few more examples where work completes at arbitrary later times.



## Yakka?
As in Hard Yakka – classic Aussie slang for work. It's derived from 'yaga', which is a term from the Yagara language spoken by indigenous peoples of the region now known as Brisbane.

## Requirements

Swift 3.0+

## Installation

Yakka is available through [CocoaPods](http://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod "Yakka"
```

## Author

Kieran Harper, kieranjharper@gmail.com

## License

Yakka is available under the MIT license. See the LICENSE file for more info.
