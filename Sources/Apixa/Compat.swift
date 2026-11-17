import SwiftUI

/// The macOS 27 SDK turns `@State` into a macro whose plugin (SwiftUIMacros) ships only with Xcode,
/// not the Command Line Tools. Aliasing the underlying property-wrapper struct sidesteps macro lookup,
/// so the app builds with CLT alone. Behaviour is identical to `@State`.
typealias ViewState<Value> = SwiftUI.State<Value>
