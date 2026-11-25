import SwiftUI

/// Famiglia di layout per i controlli a schermo.
enum ControllerFamily {
    case playstation   // PS1 / PS2
    case psp
    case snes
    case nes           // NES e Game Boy
    case gba
    case genesis
    case n64
}

enum GameSystem: String, Codable, CaseIterable, Identifiable {
    case ps1, ps2, psp, n64, snes, nes, gba, gb, megadrive

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ps1: return "PlayStation"
        case .ps2: return "PlayStation 2"
        case .psp: return "PlayStation Portable"
        case .n64: return "Nintendo 64"
        case .snes: return "Super Nintendo"
        case .nes: return "NES"
        case .gba: return "Game Boy Advance"
        case .gb: return "Game Boy / Color"
        case .megadrive: return "Mega Drive / Master System"
        }
    }

    var shortName: String {
        switch self {
        case .ps1: return "PS1"
        case .ps2: return "PS2"
        case .psp: return "PSP"
        case .n64: return "N64"
        case .snes: return "SNES"
        case .nes: return "NES"
        case .gba: return "GBA"
        case .gb: return "GB"
        case .megadrive: return "MD"
        }
    }

    /// Nome del framework del core libretro incluso nell'app.
    var coreFramework: String {
        switch self {
        case .ps1: return "pcsx_rearmed_libretro_ios"
        case .ps2: return "play_libretro_ios"
        case .psp: return "ppsspp_libretro_ios"
        case .n64: return "mupen64plus_next_libretro_ios"
        case .snes: return "snes9x_libretro_ios"
        case .nes: return "fceumm_libretro_ios"
        case .gba: return "mgba_libretro_ios"
        case .gb: return "gambatte_libretro_ios"
        case .megadrive: return "genesis_plus_gx_libretro_ios"
        }
    }

    var coreDisplayName: String {
        switch self {
        case .ps1: return "PCSX ReARMed"
        case .ps2: return "Play!"
        case .psp: return "PPSSPP"
        case .n64: return "Mupen64Plus-Next"
        case .snes: return "Snes9x"
        case .nes: return "FCEUmm"
        case .gba: return "mGBA"
        case .gb: return "Gambatte"
        case .megadrive: return "Genesis Plus GX"
        }
    }

    var extensions: [String] {
        switch self {
        case .ps1: return ["cue", "bin", "img", "chd", "pbp", "m3u", "iso", "ccd", "mdf", "toc"]
        case .ps2: return ["iso", "chd", "cso", "bin", "cue", "elf", "isz"]
        case .psp: return ["iso", "cso", "pbp", "chd", "elf", "prx"]
        case .n64: return ["n64", "z64", "v64", "ndd"]
        case .snes: return ["sfc", "smc", "fig", "swc", "bs", "st"]
        case .nes: return ["nes", "fds", "unf", "unif"]
        case .gba: return ["gba", "agb"]
        case .gb: return ["gb", "gbc", "dmg", "sgb"]
        case .megadrive: return ["md", "gen", "smd", "sms", "gg", "sg", "68k", "mdx"]
        }
    }

    var family: ControllerFamily {
        switch self {
        case .ps1, .ps2: return .playstation
        case .psp: return .psp
        case .n64: return .n64
        case .snes: return .snes
        case .nes, .gb: return .nes
        case .gba: return .gba
        case .megadrive: return .genesis
        }
    }

    var hasAnalogSticks: Bool {
        switch self {
        case .ps1, .ps2, .psp, .n64: return true
        default: return false
        }
    }

    var hasRightStick: Bool { self == .ps1 || self == .ps2 }

    /// Il core non funziona (o quasi) senza JIT.
    var requiresJIT: Bool { self == .ps2 }

    /// Il core va molto meglio con il JIT.
    var benefitsFromJIT: Bool { self == .ps2 || self == .psp || self == .n64 || self == .ps1 }

    /// Dispositivo per la porta 1 (RETRO_DEVICE_*). PS1: DualShock.
    var portDevice: UInt32 {
        switch self {
        case .ps1: return 517 // DualShock: RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 1)
        default: return 1
        }
    }

    var accent: Color {
        switch self {
        case .ps1: return Color(red: 0.55, green: 0.58, blue: 0.65)
        case .ps2: return Color(red: 0.20, green: 0.35, blue: 0.85)
        case .psp: return Color(red: 0.35, green: 0.35, blue: 0.40)
        case .n64: return Color(red: 0.15, green: 0.55, blue: 0.30)
        case .snes: return Color(red: 0.45, green: 0.35, blue: 0.75)
        case .nes: return Color(red: 0.80, green: 0.20, blue: 0.20)
        case .gba: return Color(red: 0.35, green: 0.25, blue: 0.70)
        case .gb: return Color(red: 0.55, green: 0.65, blue: 0.20)
        case .megadrive: return Color(red: 0.10, green: 0.10, blue: 0.12)
        }
    }

    var symbol: String {
        switch self {
        case .psp, .gba, .gb: return "gamecontroller"
        default: return "opticaldisc"
        }
    }

    /// Opzioni dei core impostate in base alla disponibilità del JIT.
    func optionOverrides(jit: Bool) -> [String: String] {
        switch self {
        case .psp:
            return [
                "ppsspp_cpu_core": jit ? "JIT" : "IR JIT",
                "ppsspp_internal_resolution": "960x544",
                "ppsspp_language": "Automatic",
                "ppsspp_frameskip": "0"
            ]
        case .ps1:
            return [
                "pcsx_rearmed_drc": jit ? "enabled" : "disabled",
                "pcsx_rearmed_show_bios_bootlogo": "disabled"
            ]
        case .n64:
            return [
                "mupen64plus-cpucore": jit ? "dynamic_recompiler" : "cached_interpreter",
                "mupen64plus-rdp-plugin": "gliden64",
                "mupen64plus-rsp-plugin": "hle",
                "mupen64plus-43screensize": "640x480"
            ]
        default:
            return [:]
        }
    }

    /// Sistemi che usano una certa estensione.
    static func systems(forExtension ext: String) -> [GameSystem] {
        let e = ext.lowercased()
        return GameSystem.allCases.filter { $0.extensions.contains(e) }
    }

    /// Tutte le estensioni giocabili.
    static var allExtensions: Set<String> {
        Set(GameSystem.allCases.flatMap { $0.extensions })
    }
}
