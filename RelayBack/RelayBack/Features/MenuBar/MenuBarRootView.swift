//
//  MenuBarRootView.swift
//  RelayBack
//
//  Placeholder popover content for S0 bootstrap. The full DISARMED / ARMED
//  popover (design handoff §1–2) is built in slice S10.
//

import SwiftUI

struct MenuBarRootView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RelayBack")
                .font(.headline)
            Text("Menu-bar agent — scaffolding (S0).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }
}

#Preview {
    MenuBarRootView()
}
