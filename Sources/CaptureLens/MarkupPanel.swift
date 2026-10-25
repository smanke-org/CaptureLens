import AppKit
import CaptureLensKit
import SwiftUI

/// The Markup tab under the picture: everything about how marks look, laid out in full
/// (the menus above the picture hold the same, for when the details are folded away), and
/// how the tools are offered.
struct MarkupPanel: View {
    @State private var editor = AnnotationEditor.shared
    @State private var prefs = Preferences.shared
    @AppStorage("editor.palettePlacement", store: AppDefaults.store) private var placementRaw = PalettePlacement.left.rawValue

    var body: some View {
        Form {
            Section("Tools") {
                Picker("Show tools as", selection: $prefs.toolStyle) {
                    ForEach(ToolStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if prefs.toolStyle == .toolbar {
                    Picker("Toolbar on the", selection: $placementRaw) {
                        ForEach(PalettePlacement.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Picker("Open the dial", selection: $prefs.dialTrigger) {
                        ForEach(DialTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            Section("Color") {
                HStack(spacing: 8) {
                    ForEach(AnnotationStyle.palette, id: \.self) { color in
                        let on = editor.style.color == color
                        Button { editor.style.color = color } label: {
                            Circle()
                                .fill(Color(cgColor: color.cgColor))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                                .frame(width: 22, height: 22)
                                .padding(3)
                                .overlay(Circle().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(AnnotationToolbar.name(color))
                    }
                    Button("Other…") { ColorPanelBridge.shared.open() }
                }
            }
            Section("Size and style") {
                LabeledContent("Lines") {
                    HStack {
                        Slider(value: $editor.style.lineWidth, in: 1...16, step: 1)
                        Text("\(Int(editor.style.lineWidth)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Text") {
                    HStack {
                        Slider(value: $editor.style.fontSize, in: 10...64, step: 2)
                        Text("\(Int(editor.style.fontSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                HStack(spacing: 16) {
                    Toggle("Bold text", isOn: $editor.style.bold)
                    Toggle("Fill", isOn: $editor.style.filled)
                    Toggle("Shadow", isOn: $editor.style.shadow)
                }
            }
            Section("Quick styles") {
                FlowLayout(spacing: 6) {
                    ForEach(prefs.quickStyles, id: \.self) { quick in
                        let on = editor.style == quick
                        Button { editor.style = quick } label: {
                            HStack(spacing: 5) {
                                Circle().fill(Color(cgColor: quick.color.cgColor)).frame(width: 10, height: 10)
                                Text("\(Int(quick.lineWidth)) pt\(quick.filled ? ", filled" : "")")
                            }
                            .font(.callout)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(AnnotationToolbar.describe(quick))
                        .contextMenu { Button("Remove") { editor.removeQuickStyle(quick) } }
                    }
                }
                HStack {
                    Button("Save Current Style") { editor.saveQuickStyle() }
                        .disabled(prefs.quickStyles.contains(editor.style))
                    if prefs.quickStyles.contains(editor.style) {
                        Button("Remove Current Style") { editor.removeQuickStyle(editor.style) }
                    }
                }
            }
            if let mark = editor.selected, let id = editor.selection {
                Section("Selected mark") {
                    if mark.kind == .stamp {
                        Picker("Stamp", selection: Binding(get: { mark.stamp }, set: { stamp in
                            editor.stamp = stamp
                            editor.change(id, action: "Change Stamp") { $0.stamp = stamp }
                        })) {
                            ForEach(AnnotationEditor.stamps, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if mark.kind == .magnify {
                        Picker("Enlarge", selection: Binding(get: { mark.zoom }, set: { zoom in
                            editor.change(id, action: "Change Zoom") { $0.zoom = zoom }
                        })) {
                            ForEach([1.5, 2, 3, 4], id: \.self) { Text("\($0.formatted())×").tag($0) }
                        }
                    }
                    HStack {
                        Button("Bring to Front") { editor.reorder(toFront: true) }
                        Button("Send to Back") { editor.reorder(toFront: false) }
                        Spacer()
                        Button("Delete", role: .destructive) { editor.deleteSelection() }
                    }
                }
            } else if editor.tool == .draw(.stamp) {
                Section("Stamp") {
                    Picker("Stamp", selection: $editor.stamp) {
                        ForEach(AnnotationEditor.stamps, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section {
                Toggle("Show marks", isOn: $editor.showAnnotations)
            } footer: {
                Text("Turn off to see the picture as it was captured. Marks are never burned into the original.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
