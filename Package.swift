import PackageDescription

let package = Package(
    name: "Yakka",
    dependencies: [
        .Package(url: "https://github.com/Quick/Quick.git", majorVersion: 1, minor: 1),
	    .Package(url: "https://github.com/Quick/Nimble.git", majorVersion: 6, minor: 1)
    ]
)
