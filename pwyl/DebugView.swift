//
//  DebugView.swift
//  pwyl
//
//  Created by Eric Weinert on 8/9/25.
//

import SwiftUI

struct DebugView: View {
    @ObservedObject var state: DebugState
    @ObservedObject var config: DebugConfig
    let onThresholdChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading) {
                Text("Eye Open Threshold (EAR)")
                HStack {
                    Slider(value: Binding(
                        get: { config.threshold },
                        set: { newValue in
                            config.threshold = newValue
                            onThresholdChange(newValue)
                        }
                    ), in: 0.05...0.35, step: 0.005) {
                        Text("EAR Threshold")
                    }
                    Text(String(format: "%.3f", config.threshold)).monospaced()
                }
                Text("Lower if it says eyesOpen=false while open; raise if it says true while blinking.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top])

            Divider()

            ScrollView {
                Text(state.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 520, minHeight: 300)
    }
}

#Preview {
    DebugView(state: DebugState(), config: DebugConfig(), onThresholdChange: { _ in })
} 