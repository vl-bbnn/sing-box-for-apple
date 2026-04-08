import Libbox
import Library
import SwiftUI

@MainActor
public struct OutboundPickerView: View {
    @Binding var selectedOutbound: String
    @StateObject private var commandClient = CommandClient(.outbounds)
    @State private var outbounds: [OutboundGroupItem] = []
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredOutbounds: [OutboundGroupItem] {
        if searchText.isEmpty {
            return outbounds
        }
        return outbounds.filter { $0.tag.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        List {
            Button {
                selectedOutbound = ""
                dismiss()
            } label: {
                HStack {
                    Text("Default")
                        .foregroundStyle(.foreground)
                    Spacer()
                    if selectedOutbound.isEmpty {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            #if os(macOS)
            .buttonStyle(.plain)
            #endif
            ForEach(filteredOutbounds, id: \.tag) { item in
                Button {
                    selectedOutbound = item.tag
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.tag)
                                .foregroundStyle(.foreground)
                                .lineLimit(1)
                            HStack {
                                Text(item.displayType)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer(minLength: 0)
                                if item.urlTestDelay > 0 {
                                    Text(item.delayString)
                                        .font(.caption)
                                        .foregroundColor(item.delayColor)
                                }
                            }
                        }
                        if selectedOutbound == item.tag {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
            }
        }
        .searchable(text: $searchText)
        .navigationTitle("Outbound")
        .onAppear {
            commandClient.connect()
        }
        .onDisappear {
            commandClient.disconnect()
        }
        .onReceive(commandClient.$outbounds) { goOutbounds in
            guard let goOutbounds else { return }
            outbounds = goOutbounds.map { item in
                OutboundGroupItem(
                    tag: item.tag,
                    type: item.type,
                    urlTestTime: Date(timeIntervalSince1970: Double(item.urlTestTime)),
                    urlTestDelay: UInt16(item.urlTestDelay)
                )
            }
        }
    }
}
