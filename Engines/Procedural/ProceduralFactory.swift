//  Waraq - A native macOS animated wallpaper app.
//  Copyright (C) 2026 Omar A. Othman
//
//  This program is free software: you can redistribute it
//  and/or modify it under the terms of the GNU General
//  Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at
//  your option) any later version.
//
//  This program is distributed in the hope that it will
//  be useful, but WITHOUT ANY WARRANTY; without even the
//  implied warranty of MERCHANTABILITY or FITNESS FOR A
//  PARTICULAR PURPOSE. See the GNU General Public License
//  for more details.
//
//  You should have received a copy of the GNU General
//  Public License along with this program. If not, see
//  <https://www.gnu.org/licenses/>.
//

import AppKit
import SwiftUI

/// Maps a procedural wallpaper key to an NSView (via NSHostingView
/// around the matching SwiftUI view).
enum ProceduralFactory {
    /// The SwiftUI view that renders a procedural key. Single source of
    /// truth, reused both for the live NSHostingView and for offscreen
    /// thumbnail capture (ProceduralThumbnailGenerator).
    static func swiftUIView(
        for key: String,
        frameRate: Double? = nil
    ) -> AnyView? {
        let frameRate = frameRate ?? defaultFrameRate(for: key)
        switch key {
        case "aurora": return AnyView(AuroraView(frameRate: frameRate))
        case "synthwave":
            return AnyView(SynthwaveView(frameRate: frameRate))
        case "starfield":
            return AnyView(StarfieldView(frameRate: frameRate))
        case "neural-network":
            return AnyView(NeuralNetworkView(frameRate: frameRate))
        default: return nil
        }
    }

    static func makeView(
        for key: String,
        frameRate: Double? = nil
    ) -> NSView? {
        guard let view = swiftUIView(for: key, frameRate: frameRate) else {
            return nil
        }
        return NSHostingView(rootView: view)
    }

    private static func defaultFrameRate(for key: String) -> Double {
        key == "starfield" ? 60 : 30
    }

    static let allBuiltIns: [Wallpaper] = [
        Wallpaper(
            id: "com.bahamut.waraq.builtin.aurora",
            name: "Aurora Borealis",
            kind: .procedural,
            addedDate: Date.distantPast,
            proceduralKey: "aurora"
        ),
        Wallpaper(
            id: "com.bahamut.waraq.builtin.synthwave",
            name: "Synthwave Drive",
            kind: .procedural,
            addedDate: Date.distantPast,
            proceduralKey: "synthwave"
        ),
        Wallpaper(
            id: "com.bahamut.waraq.builtin.starfield",
            name: "Starfield",
            kind: .procedural,
            addedDate: Date.distantPast,
            proceduralKey: "starfield"
        ),
        Wallpaper(
            id: "com.bahamut.waraq.builtin.neural",
            name: "Neural Network",
            kind: .procedural,
            addedDate: Date.distantPast,
            proceduralKey: "neural-network"
        ),
    ]
}
