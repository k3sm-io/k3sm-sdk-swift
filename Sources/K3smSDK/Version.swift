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

/// The SDK's own version. The client API is still being designed; these
/// constants are the only public declarations the SDK carries until that design
/// is settled.
public enum K3smSDKVersion {
    /// The major version.
    public static let major = 0
    /// The minor version.
    public static let minor = 0
    /// The patch version.
    public static let patch = 0
    /// The version as "major.minor.patch".
    public static let string = "0.0.0"
}
