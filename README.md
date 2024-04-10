A small library, similar to Codable, that uses macro annotations to generate a binary format. This format can be stored on disk, or communicated over a network.

## Defining Types

```swift
import SwiftBin

@BinaryFormat struct UserSession {
    let iosVersion: Int
    let username: String
    var actions: [UserAction]
}

@OpenBinaryEnum enum UserAction {
    // Supports regular enum cases
    case appMovedToForeground, appMovedToBackground

    // Also supports associated values
    case searchInTimeline(String)
    case sendChatMessage(String, toUserId: String)

    // Adding values at the end of an `OpenBinaryEnum` is non-breaking, adding new cases elsewhere is breaking.
}
```

### Foundation Support

You can use convenience APIs to write the buffer into `Data`. This works well for iOS apps.

```swift
var session = UserSession(..)
let data = try session.writeData()
```

You can use convenience APIs for parsing as well.

```swift
let parsedSession = try UserSession(parseFrom: data)
```

## Bring your own types!

SwiftNIO is used on the Server, and who knows what's next! Types are serialized into a `BinaryWriter`. You can create your own BinaryWriter that sends the data over a socket, into SwiftNIO ByteBuffer or writes it to the FileSystem.

```swift
var writer = BinaryWriter { data in
    // Callback is triggered for `data` that needs to be written
    // This can throw an error
}

try session.serialize(into: writer)
```

You can flush on-write, buffer it yourself, or flush after use.

### Read from Buffers

Likewise, `BinaryBuffer` can be used to represent data. It's initialized with a pointer and count, allowing it to be used with most data types.

```swift
let userSession = try data.withUnsafeBytes { buffer in
    let buffer = buffer.bindMemory(to: UInt8.self)
    var binary = BinaryBuffer(
        pointer: buffer.baseAddress!,
        count: buffer.count,
        release: nil
    )

    return try UserSession(consuming: &binary)
}
```