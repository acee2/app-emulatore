import SwiftUI

/// Chiede a quale console appartengono i file con estensione ambigua (es. .iso, .chd, .cue).
struct AssignmentSheet: View {
    @State var assignments: [PendingAssignment]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($assignments) { $a in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(a.title).font(.headline)
                            Picker("Console", selection: $a.selected) {
                                ForEach(a.options) { s in Text(s.shortName).tag(s) }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("Questi file possono appartenere a più console. Ho scelto quella più probabile: controlla e conferma. Puoi cambiarla anche dopo tenendo premuto sul gioco.")
                }
            }
            .navigationTitle("Per quale console?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Conferma") {
                        LibraryStore.shared.confirmAssignments(assignments)
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
