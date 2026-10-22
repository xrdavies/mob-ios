import SwiftUI

/// Licences of mob-ios and of the code it ships. WebRTC (stasel/WebRTC, a build of Google's libwebrtc) is
/// the only third-party package; the components it bundles were read from the shipped binary.
enum Acknowledgements {
    struct Item: Identifiable {
        let name: String
        let license: String
        let url: String
        var text: String? = nil
        var id: String { name }
    }

    static let mob = Item(name: "Mob for iOS", license: "MIT", url: "https://github.com/xrdavies/mob-ios", text: """
MIT License

Copyright (c) 2026 Frozen and MOB contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
""")

    static let webrtc = Item(name: "WebRTC (libwebrtc, via stasel/WebRTC)", license: "BSD 3-Clause", url: "https://webrtc.googlesource.com/src", text: """
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
""")

    /// Third-party code inside the WebRTC binary, each under its own licence.
    static let bundled: [Item] = [
        Item(name: "BoringSSL", license: "Apache 2.0; older parts OpenSSL and ISC", url: "https://boringssl.googlesource.com/boringssl"),
        Item(name: "Abseil", license: "Apache 2.0", url: "https://github.com/abseil/abseil-cpp"),
        Item(name: "dav1d", license: "BSD 2-Clause", url: "https://code.videolan.org/videolan/dav1d"),
        Item(name: "libaom", license: "BSD 2-Clause, AOM Patent License 1.0", url: "https://aomedia.googlesource.com/aom"),
        Item(name: "libsrtp", license: "BSD 3-Clause", url: "https://github.com/cisco/libsrtp"),
        Item(name: "libvpx", license: "BSD 3-Clause", url: "https://chromium.googlesource.com/webm/libvpx"),
        Item(name: "libyuv", license: "BSD 3-Clause", url: "https://chromium.googlesource.com/libyuv/libyuv"),
        Item(name: "Opus", license: "BSD 3-Clause", url: "https://opus-codec.org"),
        Item(name: "Protocol Buffers", license: "BSD 3-Clause", url: "https://github.com/protocolbuffers/protobuf"),
    ]
}

/// Settings → About → Acknowledgements.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section { licenseRow(Acknowledgements.mob) }
            Section {
                licenseRow(Acknowledgements.webrtc)
            } header: {
                Text("Live desktop")
            } footer: {
                Text("WebRTC includes the third-party components below.")
            }
            Section("Included in WebRTC") {
                ForEach(Acknowledgements.bundled) { item in
                    Link(destination: URL(string: item.url)!) {
                        LabeledContent(item.name, value: item.license)
                    }
                }
            }
        }
        .navigationTitle("Acknowledgements")
    }

    private func licenseRow(_ item: Acknowledgements.Item) -> some View {
        NavigationLink {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Link(item.url, destination: URL(string: item.url)!).font(.footnote)
                    Text(item.text ?? "").font(.footnote.monospaced()).textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(item.name, value: item.license)
        }
    }
}
