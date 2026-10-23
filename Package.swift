// swift-tools-version:6.0
/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import PackageDescription

let package = Package(
    name: "K3smSDK",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "K3smSDK", targets: ["K3smSDK"]),
    ],
    targets: [
        // The page reader's seqlock primitives in C11 atomics; part of the
        // library, not a product of its own.
        .target(name: "CK3smPage"),
        .target(name: "K3smSDK", dependencies: ["CK3smPage"]),
        // The vendored fixtures are read from the source tree by path, not
        // bundled as resources.
        .testTarget(name: "K3smSDKTests", dependencies: ["K3smSDK"], exclude: ["Fixtures"]),
    ]
)
