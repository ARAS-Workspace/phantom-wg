import SwiftUI

/// Yeniden kullanılabilir form field bileşenleri.
///
/// TunnelDetailView'daki textField/portField/intField builder fonksiyonlarını
/// bağımsız, yeniden kullanılabilir SwiftUI View'lar olarak sunar.
/// Disabled durumu ve foreground stili PhantomUIEngine'den alınır.
///
/// Reusable form field components.
///
/// Extracts the textField/portField/intField builder functions from TunnelDetailView
/// into independent, reusable SwiftUI Views.
/// Disabled state and foreground style are driven by PhantomUIEngine.

/// Monospaced metin giriş alanı — label üstte, değer altta.
/// Aktif tunnel sırasında disabled olur ve secondary renge geçer.
///
/// Monospaced text input field — label on top, value below.
/// Becomes disabled during active tunnel and switches to secondary color.
struct PhantomTextField: View {
    let label: String
    @Binding var text: String
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .disabled(isDisabled)
                .foregroundStyle(isDisabled ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }
}

/// Generic sayısal giriş alanı — UInt16 (port) ve Int (MTU, keepalive) için tek bileşen.
/// String ↔ sayı dönüşümünü dahili binding ile yönetir.
///
/// Generic numeric input field — single component for UInt16 (port) and Int (MTU, keepalive).
/// Manages String ↔ number conversion through an internal binding.
struct PhantomNumericField<T: FixedWidthInteger & LosslessStringConvertible>: View {
    let label: String
    @Binding var value: T
    let isDisabled: Bool

    var body: some View {
        let stringBinding = Binding<String>(
            get: { "\(value)" },
            set: { if let v = T($0) { value = v } }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: stringBinding)
                .font(.system(.body, design: .monospaced))
                .disabled(isDisabled)
                .foregroundStyle(isDisabled ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }
}
