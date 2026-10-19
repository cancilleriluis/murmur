import AppKit
import SwiftUI

/// A small window for the settings people actually change, so editing
/// config.json is only needed for the advanced ones.
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: ConfigStore
    private let onSave: () -> Void

    init(store: ConfigStore, onSave: @escaping () -> Void) {
        self.store = store
        self.onSave = onSave
    }

    func show() {
        let model = SettingsModel(config: store.config)
        let view = SettingsView(
            model: model,
            save: { [weak self] in
                guard let self = self else { return }
                self.store.update { model.apply(to: &$0) }
                self.onSave()
                self.window?.close()
            },
            openJSON: { NSWorkspace.shared.open(Paths.configFile) })

        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Ajustes de VoZ"
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.contentViewController = NSHostingController(rootView: view)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct Choice: Identifiable, Hashable {
    let id: String
    let label: String
}

final class SettingsModel: ObservableObject {
    @Published var hotkey: String
    @Published var doubleTap: Bool
    @Published var commandMode: Bool
    @Published var micWarm: Double
    @Published var modelPath: String
    @Published var live: Bool
    @Published var cleanup: Bool
    @Published var style: String
    @Published var minWords: Int
    @Published var vocabulary: String

    init(config: Config) {
        hotkey = config.hotkey
        doubleTap = config.double_tap_lock
        commandMode = config.command_mode
        micWarm = config.mic_warm_seconds
        modelPath = config.whisper_model_path
        live = config.live_transcription
        cleanup = config.cleanup.enabled
        style = config.cleanup.style
        minWords = config.cleanup.min_words
        vocabulary = config.vocabulary.joined(separator: "\n")
    }

    func apply(to config: inout Config) {
        config.hotkey = hotkey
        config.double_tap_lock = doubleTap
        config.command_mode = commandMode
        config.mic_warm_seconds = micWarm
        config.whisper_model_path = modelPath
        config.live_transcription = live
        config.cleanup.enabled = cleanup
        config.cleanup.style = style
        config.cleanup.min_words = minWords
        config.vocabulary = vocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let save: () -> Void
    let openJSON: () -> Void

    static let hotkeys = [
        Choice(id: "fn", label: "fn (Globo)"),
        Choice(id: "right_option", label: "⌥ derecha"),
        Choice(id: "left_option", label: "⌥ izquierda"),
        Choice(id: "right_command", label: "⌘ derecha"),
        Choice(id: "right_control", label: "⌃ derecha"),
        Choice(id: "right_shift", label: "⇧ derecha"),
    ]

    static let styles = [
        Choice(id: "auto", label: "Auto — organiza si enumeras puntos"),
        Choice(id: "clean", label: "Solo limpiar (prosa)"),
        Choice(id: "structured", label: "Siempre título + puntos"),
        Choice(id: "casual", label: "Mensaje informal"),
        Choice(id: "email", label: "Email"),
    ]

    private var models: [Choice] {
        [Choice(id: "", label: "Automático (el más grande instalado)")]
            + ModelLibrary.installed().map { Choice(id: $0.path, label: ModelLibrary.label($0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Dictado") {
                    Picker("Tecla", selection: $model.hotkey) {
                        ForEach(Self.hotkeys) { Text($0.label).tag($0.id) }
                    }
                    Toggle("Doble toque: dictar sin mantener la tecla", isOn: $model.doubleTap)
                    Toggle("Modo comando (tecla + ⇧ con texto seleccionado)", isOn: $model.commandMode)
                    Stepper(value: $model.micWarm, in: 0...600, step: 15) {
                        Text(model.micWarm == 0
                             ? "Micrófono: se cierra al soltar"
                             : "Micrófono abierto \(Int(model.micWarm)) s tras dictar")
                    }
                }
                Section("Transcripción") {
                    Picker("Modelo", selection: $model.modelPath) {
                        ForEach(models) { Text($0.label).tag($0.id) }
                    }
                    Toggle("Transcribir mientras hablas", isOn: $model.live)
                }
                Section("Limpieza con IA") {
                    Toggle("Activada", isOn: $model.cleanup)
                    Picker("Formato por defecto", selection: $model.style) {
                        ForEach(Self.styles) { Text($0.label).tag($0.id) }
                    }
                    Stepper(value: $model.minWords, in: 0...40) {
                        Text(model.minWords == 0
                             ? "Usar IA siempre"
                             : "Sin IA con menos de \(model.minWords) palabras")
                    }
                }
                Section("Vocabulario — un nombre o término por línea") {
                    TextEditor(text: $model.vocabulary)
                        .font(.body)
                        .frame(minHeight: 120)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Ajustes avanzados (JSON)…", action: openJSON)
                Spacer()
                Button("Guardar", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 500, height: 640)
    }
}
