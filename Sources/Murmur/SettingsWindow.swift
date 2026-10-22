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
                // Keys first: if the .env can't be written, keep the window
                // open with the error rather than close it as if it saved.
                do {
                    try model.saveKeys()
                } catch {
                    model.keyError = "No se pudieron guardar las claves: \(error.localizedDescription)"
                    return
                }
                self.store.update { model.apply(to: &$0) }
                self.onSave()
                self.window?.close()
            },
            openJSON: { NSWorkspace.shared.open(Paths.configFile) })

        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 720),
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

/// One API key as the settings window shows it. The saved value is never put
/// back into a field — only its last four characters, so you can tell which
/// key is in there — and an empty field means "leave it as it is".
final class KeyEntry: ObservableObject, Identifiable {
    let id: String          // the .env name, e.g. OPENAI_API_KEY
    let label: String
    @Published var draft = ""
    @Published var remove = false
    let savedSuffix: String?

    init(id: String, label: String) {
        self.id = id
        self.label = label
        savedSuffix = Env.get(id).map { String($0.suffix(4)) }
    }

    var status: String {
        if remove { return "Se borrará al guardar" }
        if !Env.sanitize(draft).isEmpty { return "Nueva clave — se guardará" }
        if let s = savedSuffix { return "Guardada ···\(s)" }
        return "Sin clave"
    }

    /// nil = untouched; .some(nil) = delete; .some(value) = set.
    var change: String?? {
        if remove { return .some(nil) }
        let clean = Env.sanitize(draft)
        return clean.isEmpty ? nil : .some(clean)
    }
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
    @Published var transcription: String
    @Published var provider: String
    @Published var keyError: String?
    let keys = [
        KeyEntry(id: "OPENAI_API_KEY", label: "OpenAI"),
        KeyEntry(id: "GROQ_API_KEY", label: "Groq"),
        KeyEntry(id: "ANTHROPIC_API_KEY", label: "Anthropic"),
        KeyEntry(id: "XAI_API_KEY", label: "xAI (Grok)"),
    ]

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
        transcription = config.transcription_backend.lowercased()
        provider = config.cleanup.provider.lowercased()
    }

    /// Writes only the keys that were changed or marked for deletion.
    func saveKeys() throws {
        var updates: [String: String?] = [:]
        for key in keys {
            if let change = key.change { updates[key.id] = change }
        }
        guard !updates.isEmpty else { return }
        try Env.write(updates)
        Log.write("API keys updated from Ajustes: \(updates.keys.sorted().joined(separator: ", "))")
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
        config.transcription_backend = transcription
        config.cleanup.provider = provider
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

    static let transcriptionBackends = [
        Choice(id: "auto", label: "Auto — local si está instalado, si no Groq → OpenAI"),
        Choice(id: "local", label: "Solo local (whisper.cpp)"),
        Choice(id: "openai", label: "OpenAI"),
        Choice(id: "groq", label: "Groq"),
    ]

    static let providers = [
        Choice(id: "auto", label: "Auto — Groq → OpenAI → Anthropic → xAI"),
        Choice(id: "openai", label: "OpenAI"),
        Choice(id: "groq", label: "Groq"),
        Choice(id: "anthropic", label: "Anthropic (Claude)"),
        Choice(id: "xai", label: "xAI (Grok)"),
        Choice(id: "local", label: "Local (Ollama, LM Studio…)"),
    ]

    /// The list, plus whatever is in config.json if it isn't one of them, so
    /// opening and saving the window never silently rewrites a hand-edited value.
    private static func choices(_ list: [Choice], keeping current: String) -> [Choice] {
        list.contains { $0.id == current } ? list : list + [Choice(id: current, label: current)]
    }

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
                    Picker("Servicio", selection: $model.transcription) {
                        ForEach(Self.choices(Self.transcriptionBackends, keeping: model.transcription)) {
                            Text($0.label).tag($0.id)
                        }
                    }
                    Toggle("Transcribir mientras hablas", isOn: $model.live)
                }
                Section("Limpieza con IA") {
                    Toggle("Activada", isOn: $model.cleanup)
                    Picker("Proveedor", selection: $model.provider) {
                        ForEach(Self.choices(Self.providers, keeping: model.provider)) {
                            Text($0.label).tag($0.id)
                        }
                    }
                    Picker("Formato por defecto", selection: $model.style) {
                        ForEach(Self.styles) { Text($0.label).tag($0.id) }
                    }
                    Stepper(value: $model.minWords, in: 0...40) {
                        Text(model.minWords == 0
                             ? "Usar IA siempre"
                             : "Sin IA con menos de \(model.minWords) palabras")
                    }
                }
                Section {
                    ForEach(model.keys) { KeyRow(entry: $0) }
                    if let error = model.keyError {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                } header: {
                    Text("Claves de API")
                } footer: {
                    Text("Pega una clave nueva para reemplazar la actual; deja el campo vacío para no tocarla. Se guardan en ~/.config/murmur/.env, solo legible por ti.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        .frame(width: 500, height: 720)
    }
}

struct KeyRow: View {
    @ObservedObject var entry: KeyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.label)
                Spacer()
                Text(entry.status)
                    .font(.caption)
                    .foregroundStyle(entry.remove ? .red : .secondary)
            }
            HStack {
                SecureField(entry.savedSuffix == nil ? "Pega la clave" : "Pega una clave nueva",
                            text: $entry.draft)
                    .disabled(entry.remove)
                if entry.savedSuffix != nil {
                    Button {
                        entry.remove.toggle()
                        if entry.remove { entry.draft = "" }
                    } label: {
                        Image(systemName: entry.remove ? "arrow.uturn.backward" : "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(entry.remove ? "No borrar" : "Borrar esta clave")
                }
            }
        }
    }
}
