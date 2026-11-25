import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var gamepads = GamepadManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Mostra controlli a schermo", isOn: $settings.showTouchControls)
                    Toggle("Nascondili quando colleghi un controller", isOn: $settings.hideControlsWithController)
                    Picker("Movimento", selection: $settings.movementStyle) {
                        ForEach(MovementStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Stick analogici (PS1, PS2, PSP)", isOn: $settings.showAnalogSticks)
                    Toggle("Scompaiono quando non li usi", isOn: $settings.autoHideControls)
                    VStack(alignment: .leading) {
                        Text("Opacità: \(Int(settings.controlsOpacity * 100))%")
                        Slider(value: $settings.controlsOpacity, in: 0.15...1.0)
                    }
                    VStack(alignment: .leading) {
                        Text("Dimensione: \(Int(settings.controlsScale * 100))%")
                        Slider(value: $settings.controlsScale, in: 0.7...1.3)
                    }
                    Toggle("Vibrazione alla pressione", isOn: $settings.haptics)
                } header: {
                    Text("Controlli a schermo")
                } footer: {
                    Text("Con \"Scompaiono\" i comandi svaniscono dopo 4 secondi senza tocchi e ricompaiono appena tocchi lo schermo.")
                }

                Section {
                    HStack {
                        Text("Stato")
                        Spacer()
                        Text(gamepads.isConnected ? (gamepads.controllerName ?? "Collegato") : "Nessun controller")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Controller")
                } footer: {
                    Text("Collega un DualShock 4, DualSense, Xbox o MFi da Impostazioni › Bluetooth. Premi L3 + R3 insieme per aprire il menu di gioco.")
                }

                Section {
                    Picker("Velocità di gioco", selection: $settings.gameSpeed) {
                        ForEach(AppSettings.speedOptions, id: \.self) { Text("\(Int($0))×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Riprendi da dove avevi lasciato", isOn: $settings.resumeFromAutoSave)
                    Toggle("Immagine sfumata", isOn: $settings.smoothFiltering)
                } header: {
                    Text("Gioco")
                } footer: {
                    Text("Quando esci da un gioco viene salvato automaticamente; la versione precedente resta come backup. Puoi usare anche 5 slot manuali dal menu di gioco.")
                }

                Section("Console") {
                    NavigationLink("BIOS e file di sistema") { BIOSView() }
                    ForEach(GameSystem.allCases) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                Text(s.coreDisplayName + (s.requiresJIT ? " · richiede JIT" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if Paths.coreURL(for: s) != nil {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Text("Non incluso").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("JIT")
                        Spacer()
                        let jit = ARCEmulator.isJITAvailable()
                        Label(jit ? "Attivo" : "Non attivo", systemImage: jit ? "bolt.fill" : "bolt.slash")
                            .foregroundStyle(jit ? .green : .secondary)
                    }
                } header: {
                    Text("Prestazioni")
                } footer: {
                    Text("Il JIT si attiva con StikDebug ogni volta che apri l'app. Senza JIT le console 8/16 bit, PS1 e molti giochi PSP funzionano lo stesso; la PS2 invece ne ha bisogno.")
                }

                Section("Info") {
                    LabeledContent("Versione", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("I giochi e i BIOS devono provenire da copie che possiedi. I file sono nella cartella dell'app, visibile in File › Sul mio iPhone › Arcadia.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}
